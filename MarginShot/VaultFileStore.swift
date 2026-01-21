import CryptoKit
import Foundation
import Security

enum VaultFileStoreError: Error {
    case missingEncryptionKey
    case invalidTextEncoding
    case encryptionFailed
}

enum VaultFileStore {
    private static let encryptionHeader = Data([0x4D, 0x53, 0x45, 0x4E, 0x43, 0x31, 0x00])
    private static let fileManager = FileManager.default
    private static let encryptionKey = KeychainStore.vaultEncryptionKeyKey
    private static let encryptionEnabledKey = "privacyLocalEncryptionEnabled"
    private static let decryptedTempDirectoryName = "marginshot-decrypted"

    static func isEncryptionEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: encryptionEnabledKey) as? Bool ?? false
    }

    static func readData(from url: URL, userDefaults: UserDefaults = .standard) throws -> Data {
        let data = try Data(contentsOf: url)
        return try decryptDataIfNeeded(data, userDefaults: userDefaults)
    }

    static func readText(
        from url: URL,
        userDefaults: UserDefaults = .standard,
        encoding: String.Encoding = .utf8
    ) throws -> String {
        let data = try readData(from: url, userDefaults: userDefaults)
        guard let text = String(data: data, encoding: encoding) else {
            throw VaultFileStoreError.invalidTextEncoding
        }
        return text
    }

    static func writeData(_ data: Data, to url: URL, userDefaults: UserDefaults = .standard) throws {
        let output = try encryptDataIfNeeded(data, userDefaults: userDefaults)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try output.write(to: url, options: .atomic)
    }

    static func writeText(_ text: String, to url: URL, userDefaults: UserDefaults = .standard) throws {
        try writeData(Data(text.utf8), to: url, userDefaults: userDefaults)
    }

    static func isEncryptedFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: encryptionHeader.count)
        return header == encryptionHeader
    }

    static func decryptedCopyURL(for url: URL, relativePath: String? = nil) -> URL? {
        do {
            let raw = try Data(contentsOf: url)
            guard isEncryptedData(raw) else { return url }
            let decrypted = try decryptDataIfNeeded(raw)
            let nameSource = relativePath ?? url.lastPathComponent
            let fileName = (nameSource as NSString).lastPathComponent
            let uniqueKey = relativePath ?? url.path
            let safeName = uniqueTempFileName(for: fileName, uniqueKey: uniqueKey)
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(decryptedTempDirectoryName, isDirectory: true)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
            let tempURL = tempDir.appendingPathComponent(safeName)
            try decrypted.write(to: tempURL, options: .atomic)
            return tempURL
        } catch {
            return nil
        }
    }

    static func cleanupDecryptedCopies() {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(decryptedTempDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: tempDir.path) else { return }
        try? fileManager.removeItem(at: tempDir)
    }

    static func ensureEncryptionKey() throws {
        _ = try loadOrCreateKey()
    }

    static func encryptDataIfNeeded(_ data: Data, userDefaults: UserDefaults = .standard) throws -> Data {
        guard isEncryptionEnabled(userDefaults: userDefaults) else { return data }
        if isEncryptedData(data) {
            return data
        }
        let key = try loadOrCreateKey()
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw VaultFileStoreError.encryptionFailed
        }
        return encryptionHeader + combined
    }

    static func decryptDataIfNeeded(_ data: Data, userDefaults: UserDefaults = .standard) throws -> Data {
        guard isEncryptedData(data) else { return data }
        let key = try loadKey()
        let combined = Data(data.dropFirst(encryptionHeader.count))
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealedBox, using: key)
    }

    static func isEncryptedData(_ data: Data) -> Bool {
        data.count > encryptionHeader.count && data.starts(with: encryptionHeader)
    }

    private static func loadOrCreateKey() throws -> SymmetricKey {
        if let stored = KeychainStore.readData(forKey: encryptionKey) {
            return SymmetricKey(data: stored)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try KeychainStore.saveData(data, forKey: encryptionKey, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        return key
    }

    private static func loadKey() throws -> SymmetricKey {
        guard let stored = KeychainStore.readData(forKey: encryptionKey) else {
            throw VaultFileStoreError.missingEncryptionKey
        }
        return SymmetricKey(data: stored)
    }

    private static func sanitizeTempFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let raw = String(mapped)
        return raw.isEmpty ? "vault-file" : raw
    }

    private static func uniqueTempFileName(for fileName: String, uniqueKey: String) -> String {
        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let safeBase = sanitizeTempFileName(baseName)
        let safeExt = sanitizeTempFileName(ext)
        let suffix = shortHash(uniqueKey)
        let nameRoot = safeBase.isEmpty ? "vault-file" : safeBase
        if safeExt.isEmpty {
            return "\(nameRoot)-\(suffix)"
        }
        return "\(nameRoot)-\(suffix).\(safeExt)"
    }

    private static func shortHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }
}

enum VaultEncryptionManager {
    private static let fileManager = FileManager.default

    static func startIfNeeded() {
        guard VaultFileStore.isEncryptionEnabled() else { return }
        Task.detached(priority: .utility) {
            do {
                try VaultFileStore.ensureEncryptionKey()
                try encryptVault()
            } catch {
                print("Vault encryption failed: \(error)")
            }
        }
    }

    static func handleSettingChange(enabled: Bool) {
        if enabled {
            startIfNeeded()
        } else {
            VaultIndexStore.shared.rebuildSearchIndex()
        }
    }

    private static func encryptVault() throws {
        let rootURL = try vaultRootURL()
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                continue
            }
            if shouldRemoveSearchIndex(fileURL) {
                try? fileManager.removeItem(at: fileURL)
                continue
            }
            let data = try Data(contentsOf: fileURL)
            if VaultFileStore.isEncryptedData(data) {
                continue
            }
            let encrypted = try VaultFileStore.encryptDataIfNeeded(data)
            try encrypted.write(to: fileURL, options: .atomic)
        }
    }

    private static func shouldRemoveSearchIndex(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "search.sqlite" || name == "search.sqlite-wal" || name == "search.sqlite-shm" {
            return url.path.contains("/vault/_system/")
        }
        return false
    }

    private static func vaultRootURL() throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VaultEncryptionError.documentsDirectoryUnavailable
        }
        return documentsURL.appendingPathComponent("vault", isDirectory: true)
    }
}

enum VaultEncryptionError: Error {
    case documentsDirectoryUnavailable
}
