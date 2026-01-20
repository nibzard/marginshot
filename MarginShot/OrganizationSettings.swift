import Foundation

enum OrganizationStyle: String, CaseIterable, Identifiable {
    case simple
    case johnnyDecimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple:
            return "Simple Folders"
        case .johnnyDecimal:
            return "Johnny.Decimal"
        }
    }
}

struct OrganizationPreferences {
    var style: OrganizationStyle {
        if let raw = UserDefaults.standard.string(forKey: "organizationStyle"),
           let style = OrganizationStyle(rawValue: raw) {
            return style
        }
        return .simple
    }

    var topicPagesEnabled: Bool {
        UserDefaults.standard.bool(forKey: "organizationTopicPagesEnabled")
    }
}

enum VaultFolder: CaseIterable {
    case inbox
    case daily
    case projects
    case meetings
    case tasks
    case learning

    var simpleName: String {
        switch self {
        case .inbox:
            return "inbox"
        case .daily:
            return "daily"
        case .projects:
            return "projects"
        case .meetings:
            return "meetings"
        case .tasks:
            return "tasks"
        case .learning:
            return "learning"
        }
    }

    var johnnyDecimalName: String {
        switch self {
        case .inbox:
            return "00_inbox"
        case .daily:
            return "01_daily"
        case .projects:
            return "10_projects"
        case .meetings:
            return "11_meetings"
        case .tasks:
            return "13_tasks"
        case .learning:
            return "20_learning"
        }
    }

    func folderName(style: OrganizationStyle) -> String {
        style == .johnnyDecimal ? johnnyDecimalName : simpleName
    }

    static func fromClassification(_ folder: String) -> VaultFolder? {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "00_inbox", "inbox":
            return .inbox
        case "01_daily", "daily":
            return .daily
        case "10_projects", "projects", "project":
            return .projects
        case "11_meetings", "meetings", "meeting":
            return .meetings
        case "13_tasks", "tasks", "task":
            return .tasks
        case "20_learning", "learning", "learn":
            return .learning
        default:
            return nil
        }
    }

    static func resolvedFolderName(from classificationFolder: String, style: OrganizationStyle) -> String? {
        guard let folder = fromClassification(classificationFolder) else { return nil }
        return folder.folderName(style: style)
    }

    static func normalizeTopLevelPath(_ path: String, style: OrganizationStyle) -> String {
        let components = path.split(separator: "/")
        guard let first = components.first else { return path }
        let firstString = String(first)
        guard let folder = fromClassification(firstString) else { return path }
        let normalizedFirst = folder.folderName(style: style)
        if normalizedFirst == firstString {
            return path
        }
        let remainder = components.dropFirst()
        if remainder.isEmpty {
            return normalizedFirst
        }
        return ([normalizedFirst] + remainder).joined(separator: "/")
    }

    static func folderNames(style: OrganizationStyle) -> [String] {
        allCases.map { $0.folderName(style: style) }
    }

    static func promptList(style: OrganizationStyle) -> String {
        folderNames(style: style).joined(separator: "|")
    }

    static var allFolderNames: Set<String> {
        Set(allCases.flatMap { [$0.simpleName, $0.johnnyDecimalName] })
    }
}
