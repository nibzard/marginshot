import CoreData
import Foundation

final class PersistenceController {
    static let shared = PersistenceController()

    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let notebook = NotebookEntity(context: context)
        notebook.id = UUID()
        notebook.name = "Default"
        notebook.isDefault = true
        notebook.createdAt = Date()

        let batch = BatchEntity(context: context)
        batch.id = UUID()
        batch.createdAt = Date()
        batch.status = BatchStatus.open.rawValue
        batch.notebook = notebook

        let scan = ScanEntity(context: context)
        scan.id = UUID()
        scan.createdAt = Date()
        scan.status = ScanStatus.captured.rawValue
        scan.imagePath = "scans/preview/page-001.jpg"
        scan.batch = batch

        let note = NoteEntity(context: context)
        note.id = UUID()
        note.path = "01_daily/preview.md"
        note.title = "Preview Note"
        note.createdAt = Date()
        note.updatedAt = Date()

        let syncState = SyncStateEntity(context: context)
        syncState.id = UUID()
        syncState.destinationType = SyncDestinationType.off.rawValue
        syncState.status = SyncRunStatus.idle.rawValue
        syncState.requiresAuth = false
        syncState.isEnabled = false

        let index = IndexEntity(context: context)
        index.id = UUID()
        index.notesCount = 1
        index.updatedAt = Date()

        do {
            try context.save()
        } catch {
            assertionFailure("Preview store failed to save: \(error)")
        }

        return controller
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        let model = Self.managedObjectModel
        container = NSPersistentContainer(name: "MarginShotModel", managedObjectModel: model)

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        let description = container.persistentStoreDescriptions.first
        description?.shouldMigrateStoreAutomatically = true
        description?.shouldInferMappingModelAutomatically = true

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved Core Data error \(error), \(error.userInfo)")
            }
        }

        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    private static let managedObjectModel: NSManagedObjectModel = {
        let model = NSManagedObjectModel()
        model.versionIdentifiers = ["v1"]

        let notebook = NSEntityDescription()
        notebook.name = "Notebook"
        notebook.managedObjectClassName = NSStringFromClass(NotebookEntity.self)
        notebook.uniquenessConstraints = [["id"]]

        let batch = NSEntityDescription()
        batch.name = "Batch"
        batch.managedObjectClassName = NSStringFromClass(BatchEntity.self)
        batch.uniquenessConstraints = [["id"]]

        let scan = NSEntityDescription()
        scan.name = "Scan"
        scan.managedObjectClassName = NSStringFromClass(ScanEntity.self)
        scan.uniquenessConstraints = [["id"]]

        let note = NSEntityDescription()
        note.name = "Note"
        note.managedObjectClassName = NSStringFromClass(NoteEntity.self)
        note.uniquenessConstraints = [["id"], ["path"]]

        let syncState = NSEntityDescription()
        syncState.name = "SyncState"
        syncState.managedObjectClassName = NSStringFromClass(SyncStateEntity.self)
        syncState.uniquenessConstraints = [["id"]]

        let index = NSEntityDescription()
        index.name = "Index"
        index.managedObjectClassName = NSStringFromClass(IndexEntity.self)
        index.uniquenessConstraints = [["id"]]

        let notebookId = attribute(name: "id", type: .UUIDAttributeType)
        let notebookName = attribute(name: "name", type: .stringAttributeType)
        let notebookIsDefault = attribute(name: "isDefault", type: .booleanAttributeType, defaultValue: false)
        let notebookDestination = attribute(name: "defaultDestination", type: .stringAttributeType, optional: true)
        let notebookRules = attribute(name: "rulesOverrides", type: .stringAttributeType, optional: true)
        let notebookCreatedAt = attribute(name: "createdAt", type: .dateAttributeType)
        let notebookUpdatedAt = attribute(name: "updatedAt", type: .dateAttributeType, optional: true)

        let batchId = attribute(name: "id", type: .UUIDAttributeType)
        let batchCreatedAt = attribute(name: "createdAt", type: .dateAttributeType)
        let batchUpdatedAt = attribute(name: "updatedAt", type: .dateAttributeType, optional: true)
        let batchStatus = attribute(name: "status", type: .stringAttributeType)

        let scanId = attribute(name: "id", type: .UUIDAttributeType)
        let scanCreatedAt = attribute(name: "createdAt", type: .dateAttributeType)
        let scanStatus = attribute(name: "status", type: .stringAttributeType)
        let scanImagePath = attribute(name: "imagePath", type: .stringAttributeType)
        let scanProcessedPath = attribute(name: "processedImagePath", type: .stringAttributeType, optional: true)
        let scanOCR = attribute(name: "ocrText", type: .stringAttributeType, optional: true)
        let scanTranscriptJSON = attribute(name: "transcriptJSON", type: .stringAttributeType, optional: true)
        let scanConfidence = attribute(name: "confidence", type: .doubleAttributeType, optional: true)
        let scanPageNumber = attribute(name: "pageNumber", type: .integer16AttributeType, optional: true)
        let scanStructuredMarkdown = attribute(name: "structuredMarkdown", type: .stringAttributeType, optional: true)
        let scanStructuredJSON = attribute(name: "structuredJSON", type: .stringAttributeType, optional: true)

        let noteId = attribute(name: "id", type: .UUIDAttributeType)
        let notePath = attribute(name: "path", type: .stringAttributeType)
        let noteTitle = attribute(name: "title", type: .stringAttributeType)
        let noteSummary = attribute(name: "summary", type: .stringAttributeType, optional: true)
        let noteTags = transformableAttribute(name: "tags")
        let noteLinks = transformableAttribute(name: "links")
        let noteCreatedAt = attribute(name: "createdAt", type: .dateAttributeType)
        let noteUpdatedAt = attribute(name: "updatedAt", type: .dateAttributeType)

        let syncId = attribute(name: "id", type: .UUIDAttributeType)
        let syncDestinationType = attribute(name: "destinationType", type: .stringAttributeType)
        let syncStatus = attribute(name: "status", type: .stringAttributeType)
        let syncLastSyncAt = attribute(name: "lastSyncAt", type: .dateAttributeType, optional: true)
        let syncLastErrorAt = attribute(name: "lastErrorAt", type: .dateAttributeType, optional: true)
        let syncErrorMessage = attribute(name: "errorMessage", type: .stringAttributeType, optional: true)
        let syncRequiresAuth = attribute(name: "requiresAuth", type: .booleanAttributeType, defaultValue: false)
        let syncIsEnabled = attribute(name: "isEnabled", type: .booleanAttributeType, defaultValue: false)
        let syncLastRevision = attribute(name: "lastSyncedRevision", type: .stringAttributeType, optional: true)

        let indexId = attribute(name: "id", type: .UUIDAttributeType)
        let indexUpdatedAt = attribute(name: "updatedAt", type: .dateAttributeType, optional: true)
        let indexNotesCount = attribute(name: "notesCount", type: .integer32AttributeType, defaultValue: 0)
        let indexPath = attribute(name: "indexPath", type: .stringAttributeType, optional: true)
        let indexStructurePath = attribute(name: "structurePath", type: .stringAttributeType, optional: true)
        let indexLastRebuildAt = attribute(name: "lastRebuildAt", type: .dateAttributeType, optional: true)

        let notebookBatches = relationship(name: "batches", destination: batch, toMany: true, deleteRule: .cascadeDeleteRule)
        let batchNotebook = relationship(name: "notebook", destination: notebook, toMany: false, deleteRule: .nullifyDeleteRule)

        let batchScans = relationship(name: "scans", destination: scan, toMany: true, deleteRule: .cascadeDeleteRule)
        let scanBatch = relationship(name: "batch", destination: batch, toMany: false, deleteRule: .nullifyDeleteRule)

        notebookBatches.inverseRelationship = batchNotebook
        batchNotebook.inverseRelationship = notebookBatches

        batchScans.inverseRelationship = scanBatch
        scanBatch.inverseRelationship = batchScans

        notebook.properties = [
            notebookId,
            notebookName,
            notebookIsDefault,
            notebookDestination,
            notebookRules,
            notebookCreatedAt,
            notebookUpdatedAt,
            notebookBatches
        ]

        batch.properties = [
            batchId,
            batchCreatedAt,
            batchUpdatedAt,
            batchStatus,
            batchNotebook,
            batchScans
        ]

        scan.properties = [
            scanId,
            scanCreatedAt,
            scanStatus,
            scanImagePath,
            scanProcessedPath,
            scanOCR,
            scanTranscriptJSON,
            scanConfidence,
            scanPageNumber,
            scanStructuredMarkdown,
            scanStructuredJSON,
            scanBatch
        ]

        note.properties = [
            noteId,
            notePath,
            noteTitle,
            noteSummary,
            noteTags,
            noteLinks,
            noteCreatedAt,
            noteUpdatedAt
        ]

        syncState.properties = [
            syncId,
            syncDestinationType,
            syncStatus,
            syncLastSyncAt,
            syncLastErrorAt,
            syncErrorMessage,
            syncRequiresAuth,
            syncIsEnabled,
            syncLastRevision
        ]

        index.properties = [
            indexId,
            indexUpdatedAt,
            indexNotesCount,
            indexPath,
            indexStructurePath,
            indexLastRebuildAt
        ]

        model.entities = [notebook, batch, scan, note, syncState, index]
        return model
    }()

    private static func attribute(
        name: String,
        type: NSAttributeType,
        optional: Bool = false,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        if let defaultValue {
            attribute.defaultValue = defaultValue
        }
        return attribute
    }

    private static func transformableAttribute(name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .transformableAttributeType
        attribute.valueTransformerName = NSSecureUnarchiveFromDataTransformerName
        attribute.isOptional = true
        return attribute
    }

    private static func relationship(
        name: String,
        destination: NSEntityDescription,
        toMany: Bool,
        deleteRule: NSDeleteRule
    ) -> NSRelationshipDescription {
        let relationship = NSRelationshipDescription()
        relationship.name = name
        relationship.destinationEntity = destination
        relationship.deleteRule = deleteRule
        relationship.minCount = 0
        relationship.maxCount = toMany ? 0 : 1
        relationship.isOptional = true
        return relationship
    }
}

@objc(NotebookEntity)
public class NotebookEntity: NSManagedObject {}

@objc(BatchEntity)
public class BatchEntity: NSManagedObject {}

@objc(ScanEntity)
public class ScanEntity: NSManagedObject {}

@objc(NoteEntity)
public class NoteEntity: NSManagedObject {}

@objc(SyncStateEntity)
public class SyncStateEntity: NSManagedObject {}

@objc(IndexEntity)
public class IndexEntity: NSManagedObject {}

public enum BatchStatus: String {
    case open
    case queued
    case processing
    case done
    case blocked
    case error
}

public enum ScanStatus: String {
    case captured
    case preprocessing
    case transcribing
    case structured
    case filed
    case error
}

public enum SyncRunStatus: String {
    case off
    case idle
    case syncing
    case error
}

public enum SyncDestinationType: String {
    case off
    case folder
    case github
    case custom
}

extension NotebookEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<NotebookEntity> {
        NSFetchRequest(entityName: "Notebook")
    }

    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var isDefault: Bool
    @NSManaged public var defaultDestination: String?
    @NSManaged public var rulesOverrides: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date?
    @NSManaged public var batches: Set<BatchEntity>
}

extension BatchEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<BatchEntity> {
        NSFetchRequest(entityName: "Batch")
    }

    @NSManaged public var id: UUID
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date?
    @NSManaged public var status: String
    @NSManaged public var notebook: NotebookEntity?
    @NSManaged public var scans: Set<ScanEntity>
}

extension ScanEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ScanEntity> {
        NSFetchRequest(entityName: "Scan")
    }

    @NSManaged public var id: UUID
    @NSManaged public var createdAt: Date
    @NSManaged public var status: String
    @NSManaged public var imagePath: String
    @NSManaged public var processedImagePath: String?
    @NSManaged public var ocrText: String?
    @NSManaged public var transcriptJSON: String?
    @NSManaged public var confidence: NSNumber?
    @NSManaged public var pageNumber: NSNumber?
    @NSManaged public var structuredMarkdown: String?
    @NSManaged public var structuredJSON: String?
    @NSManaged public var batch: BatchEntity?
}

extension NoteEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<NoteEntity> {
        NSFetchRequest(entityName: "Note")
    }

    @NSManaged public var id: UUID
    @NSManaged public var path: String
    @NSManaged public var title: String
    @NSManaged public var summary: String?
    @NSManaged public var tags: [String]?
    @NSManaged public var links: [String]?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
}

extension SyncStateEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<SyncStateEntity> {
        NSFetchRequest(entityName: "SyncState")
    }

    @NSManaged public var id: UUID
    @NSManaged public var destinationType: String
    @NSManaged public var status: String
    @NSManaged public var lastSyncAt: Date?
    @NSManaged public var lastErrorAt: Date?
    @NSManaged public var errorMessage: String?
    @NSManaged public var requiresAuth: Bool
    @NSManaged public var isEnabled: Bool
    @NSManaged public var lastSyncedRevision: String?
}

extension IndexEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<IndexEntity> {
        NSFetchRequest(entityName: "Index")
    }

    @NSManaged public var id: UUID
    @NSManaged public var updatedAt: Date?
    @NSManaged public var notesCount: Int32
    @NSManaged public var indexPath: String?
    @NSManaged public var structurePath: String?
    @NSManaged public var lastRebuildAt: Date?
}
