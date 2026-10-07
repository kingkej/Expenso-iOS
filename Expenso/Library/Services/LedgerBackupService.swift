import CoreData
import CryptoKit
import Foundation

struct LedgerBackupPreferences: Codable, Equatable, Sendable {
    let baseCurrency: String
    let accent: String
    // Optional so v1 archives re-encode identically for their original checksum.
    var categories: [ExpenseCategory]?

    @MainActor
    init(defaults: UserDefaults) {
        let base = defaults.string(forKey: CurrencySettings.key) ?? "RUB"
        baseCurrency = CurrencySettings.codes.contains(base) ? base : "RUB"
        accent = AppAccent.resolve(defaults.string(forKey: AppAccent.storageKey) ?? "").rawValue
        categories = CategoryCatalog.load(defaults: defaults)
    }
}

struct LedgerBackupPayload: Codable, Equatable, Sendable {
    let format: String
    let version: Int
    let createdAt: Date
    let preferences: LedgerBackupPreferences
    let records: [LedgerRecord]
}

struct LedgerBackupEnvelope: Codable, Sendable {
    let payload: LedgerBackupPayload
    let sha256: String
}

enum LedgerBackupError: LocalizedError {
    case invalidFile, unsupportedVersion, corrupted, tooLarge, invalidRecord, ledgerChanged, schemaMismatch
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "Choose a complete Expenso backup, not a CSV export."
        case .unsupportedVersion: return "This backup uses a newer or unsupported format. Update Expenso before restoring it."
        case .corrupted: return "The backup's integrity check failed. Nothing was restored."
        case .tooLarge: return "This backup exceeds the supported 256 MB or 100,000-transaction limit. Nothing was restored."
        case .invalidRecord: return "The backup contains invalid or oversized records. Nothing was restored."
        case .ledgerChanged: return "Your ledger changed while preparing restore. Review the current data and try again."
        case .schemaMismatch: return "This app's storage model cannot preserve all backup fields. Nothing was restored."
        }
    }
}

/// Deterministic checksum detects accidental corruption; it is not encryption or authentication.
enum LedgerBackupCodec {
    static let maximumBytes = 256 * 1_024 * 1_024
    static let format = "ExpensoLedgerBackup"
    static let version = 3

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder // Default Date coding preserves its Double reference-date representation.
    }

    static func encode(_ payload: LedgerBackupPayload) throws -> Data {
        try validate(payload)
        let hash = SHA256.hash(data: try encoder().encode(payload)).map { String(format: "%02x", $0) }.joined()
        let data = try encoder().encode(LedgerBackupEnvelope(payload: payload, sha256: hash))
        guard data.count <= maximumBytes else { throw LedgerBackupError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> LedgerBackupPayload {
        guard data.count <= maximumBytes else { throw LedgerBackupError.tooLarge }
        let envelope: LedgerBackupEnvelope
        do { envelope = try JSONDecoder().decode(LedgerBackupEnvelope.self, from: data) }
        catch { throw LedgerBackupError.invalidFile }
        try validate(envelope.payload)
        let hash = SHA256.hash(data: try encoder().encode(envelope.payload)).map { String(format: "%02x", $0) }.joined()
        guard envelope.sha256 == hash else { throw LedgerBackupError.corrupted }
        return envelope.payload
    }

    static func validate(_ payload: LedgerBackupPayload) throws {
        guard payload.format == format else { throw LedgerBackupError.invalidFile }
        guard (1...version).contains(payload.version) else { throw LedgerBackupError.unsupportedVersion }
        if let categories = payload.preferences.categories {
            do { try CategoryCatalog.validate(categories) }
            catch { throw LedgerBackupError.invalidFile }
        } else if payload.version >= 2 { throw LedgerBackupError.invalidFile }
        guard payload.records.count <= 100_000 else { throw LedgerBackupError.tooLarge }
        guard payload.createdAt.timeIntervalSinceReferenceDate.isFinite,
              CurrencySettings.codes.contains(payload.preferences.baseCurrency),
              AppAccent(rawValue: payload.preferences.accent) != nil else { throw LedgerBackupError.invalidFile }
        var ids: Set<String> = []
        var bytes = 0
        for record in payload.records {
            guard !record.id.isEmpty, record.id.utf8.count <= 2_048,
                  ids.insert(record.id).inserted, record.amount.isFinite else {
                throw LedgerBackupError.invalidRecord
            }
            for date in [record.createdAt, record.updatedAt, record.occuredOn].compactMap({ $0 }) {
                guard date.timeIntervalSinceReferenceDate.isFinite else { throw LedgerBackupError.invalidRecord }
            }
            guard payload.version >= 3 || record.paymentMethod == nil else { throw LedgerBackupError.invalidRecord }
            for text in [record.title, record.note, record.tag, record.type, record.currencyCode, record.amountText, record.paymentMethod].compactMap({ $0 }) {
                guard text.utf8.count <= 4 * 1_024 * 1_024 else { throw LedgerBackupError.invalidRecord }
                bytes += text.utf8.count
            }
            bytes += (record.imageAttached?.count ?? 0) + (record.rateSnapshotData?.count ?? 0)
            guard bytes <= maximumBytes else { throw LedgerBackupError.tooLarge }
            // Unknown legacy categories/types and raw optional metadata are preserved,
            // not normalized or dropped. Report/render boundaries handle invalid rates.
        }
    }
}

actor LedgerBackupIO {
    static let shared = LedgerBackupIO()

    func encode(_ payload: LedgerBackupPayload) throws -> Data { try LedgerBackupCodec.encode(payload) }

    func read(_ url: URL) throws -> LedgerBackupPayload {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= LedgerBackupCodec.maximumBytes else { throw LedgerBackupError.tooLarge }
        try Task.checkCancellation()
        return try LedgerBackupCodec.decode(Data(contentsOf: url, options: .mappedIfSafe))
    }

    func writeRecovery(_ payload: LedgerBackupPayload, directory: URL) throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Recovery-\(UUID().uuidString).expenso")
        try LedgerBackupCodec.encode(payload).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

@MainActor
enum LedgerBackupService {
    static let recoveryFilenameKey = "backups.latestRecoveryFilename"

    static func recoveryDirectory() throws -> URL {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LedgerBackupError.invalidFile
        }
        return root.appendingPathComponent("LedgerRecovery", isDirectory: true)
    }

    static func latestRecovery(defaults: UserDefaults = .standard, recoveryDirectory: URL? = nil) throws -> URL? {
        guard let filename = defaults.string(forKey: recoveryFilenameKey),
              let url = managedRecovery(filename: filename,
                  directory: try recoveryDirectory ?? self.recoveryDirectory()),
              isRegularRecovery(url) else { return nil }
        return url
    }

    private static func managedRecovery(filename: String, directory: URL) -> URL? {
        let prefix = "Recovery-"
        let suffix = ".expenso"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix),
              UUID(uuidString: String(filename.dropFirst(prefix.count).dropLast(suffix.count))) != nil else { return nil }
        return directory.standardizedFileURL.appendingPathComponent(filename)
    }

    private static func isRegularRecovery(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    static func capture(context: NSManagedObjectContext, defaults: UserDefaults = .standard) throws -> LedgerBackupPayload {
        _ = try LedgerStoreTransaction.workspace(for: context) // Reject pending edits/unsupported contexts.
        let records = try LedgerStoreTransaction.records(in: context).map(LedgerRecord.init).sorted { $0.id < $1.id }
        return LedgerBackupPayload(format: LedgerBackupCodec.format, version: LedgerBackupCodec.version,
            createdAt: Date(), preferences: LedgerBackupPreferences(defaults: defaults), records: records)
    }

    /// Whole-ledger replacement, never an implicit merge. All rows commit in one save.
    /// Preferences are allowlisted; biometric/security settings never change on restore.
    @discardableResult
    static func restore(_ payload: LedgerBackupPayload, context: NSManagedObjectContext,
                        defaults: UserDefaults = .standard, recoveryDirectory: URL? = nil,
                        recoveryWriter: (@MainActor (LedgerBackupPayload, URL) async throws -> URL)? = nil) async throws -> URL {
        try LedgerBackupCodec.validate(payload)
        let categoryData = try JSONEncoder().encode(payload.preferences.categories ?? CategoryCatalog.defaults)
        let attributes = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["ExpenseCD"]?.attributesByName
        guard ["amount", "amountText", "currencyCode", "rateSnapshotData", "createdAt", "updatedAt", "title", "note", "type", "tag", "occuredOn", "imageAttached"]
            .allSatisfy({ attributes?[$0] != nil }) else { throw LedgerBackupError.schemaMismatch }
        guard attributes?["paymentMethod"] != nil || payload.records.allSatisfy({ $0.paymentMethod == nil }) else {
            throw LedgerBackupError.schemaMismatch
        }
        let before = try capture(context: context, defaults: defaults)
        let directory = try recoveryDirectory ?? self.recoveryDirectory()
        let recovery: URL
        if let recoveryWriter {
            recovery = try await recoveryWriter(before, directory)
        } else {
            recovery = try await LedgerBackupIO.shared.writeRecovery(before, directory: directory)
        }
        // Only publish an archive owned by this recovery directory. A failed
        // writer must not hide the previous usable recovery or prune its file.
        guard let managed = managedRecovery(filename: recovery.lastPathComponent, directory: directory),
              managed == recovery.standardizedFileURL, isRegularRecovery(managed) else {
            throw LedgerBackupError.invalidFile
        }
        let previousFilename = defaults.string(forKey: recoveryFilenameKey)
        defaults.set(managed.lastPathComponent, forKey: recoveryFilenameKey)
        // The newest complete recovery survives cancellation or a later save
        // failure. Prune just the old pointer, never arbitrary directory files.
        if let previousFilename, let previous = managedRecovery(filename: previousFilename, directory: directory),
           previous != managed, isRegularRecovery(previous) {
            try? FileManager.default.removeItem(at: previous)
        }
        try Task.checkCancellation()
        let latest = try capture(context: context, defaults: defaults)
        guard before.records == latest.records, before.preferences == latest.preferences else {
            throw LedgerBackupError.ledgerChanged
        }
        let workspace = try LedgerStoreTransaction.workspace(for: context)
        for record in try LedgerStoreTransaction.records(in: workspace) { workspace.delete(record) }
        for record in payload.records { record.apply(to: try LedgerStoreTransaction.insert(in: workspace)) }
        try LedgerStoreTransaction.save(workspace, mergingInto: context)
        defaults.set(payload.preferences.baseCurrency, forKey: CurrencySettings.key)
        defaults.set(payload.preferences.accent, forKey: AppAccent.storageKey)
        defaults.set(categoryData, forKey: CategoryCatalog.storageKey)
        return recovery
    }
}
