import CoreData
import SwiftUI
import UniformTypeIdentifiers

struct LedgerBackupDocument: FileDocument {
    static let contentType = UTType(exportedAs: "com.expenso.ledger-backup", conformingTo: .json)
    static var readableContentTypes: [UTType] { [contentType, .json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw LedgerBackupError.invalidFile }
        guard data.count <= LedgerBackupCodec.maximumBytes else { throw LedgerBackupError.tooLarge }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct RestorePreview: Identifiable {
    let id = UUID()
    let payload: LedgerBackupPayload
    let currentCount: Int
}

struct BackupRestoreView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var ledgerMutations: LedgerMutationService
    @State private var document: LedgerBackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var isBusy = false
    @State private var preview: RestorePreview?
    @State private var confirmRestore = false
    @State private var errorMessage: String?
    @State private var status: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        NavigationStack {
        ExpenseForm {
            Section {
                Button("Create Backup", systemImage: "externaldrive.badge.plus") { createBackup() }
                Button("Choose Backup to Restore", systemImage: "arrow.counterclockwise") {
                    preview = nil
                    status = nil
                    importing = true
                }
                if (try? LedgerBackupService.latestRecovery()) != nil {
                    Button("Export Latest Recovery Backup", systemImage: "lifepreserver") { exportRecovery() }
                }
            } header: { Text("Your Transactions") } footer: {
                Text("Save your transactions, attachments, categories and appearance. CSV exports are not full backups.")
            }
            .disabled(isBusy)

            if let preview {
                Section("Restore Preview") {
                    ExpenseValueRow(title: "Backup Created") { Text(preview.payload.createdAt.formatted(date: .abbreviated, time: .shortened)) }
                    ExpenseValueRow(title: "Transactions in Backup") { Text("\(preview.payload.records.count)") }
                    ExpenseValueRow(title: "Attachments") { Text("\(preview.payload.records.filter { $0.imageAttached != nil }.count)") }
                    ExpenseValueRow(title: "Base Currency") { Text(preview.payload.preferences.baseCurrency) }
                    ExpenseValueRow(title: "Current Transactions") { Text("\(preview.currentCount)") }
                    DisclosureGroup("Categories to Restore (\((preview.payload.preferences.categories ?? CategoryCatalog.defaults).count))") {
                        ForEach(preview.payload.preferences.categories ?? CategoryCatalog.defaults) { category in
                            Label(category.name + (category.isArchived ? " (Archived)" : ""), systemImage: category.symbol)
                        }
                    }
                    if preview.payload.preferences.categories == nil {
                        Text("This older backup has no category settings. Restoring it resets categories to the original built-in list.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Restore replaces the entire current ledger and category settings, including names, symbols, order and archived status. It does not merge or append records. A recovery backup of the current ledger and categories is saved on this device before any replacement. Undo history and previous chat answers are cleared.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Replace Ledger with This Backup", systemImage: "arrow.counterclockwise", role: .destructive) {
                        confirmRestore = true
                    }
                    .disabled(isBusy)
                    Button("Discard Preview", role: .cancel) { self.preview = nil }.disabled(isBusy)
                }
            }

            if isBusy { Section { ProgressView("Preparing your transactions…") } }
            if let status { Section { Text(status).foregroundStyle(.secondary) } }
            Section("Privacy & Recovery") {
                Label("Backups are not encrypted", systemImage: "lock.open")
                Text("Backups contain financial data and receipt images. Keep them in a private location and only restore files you trust.")
                DisclosureGroup("Backup details") {
                    Text("Includes original amounts, saved exchange rates, dates, notes, receipt images, categories, main currency and accent. Security settings stay unchanged. Chat history and spending types are not included.")
                    Text("Choosing iCloud or another Files provider stores the backup there. Expenso does not upload it itself. Keep an external copy: deleting the app also deletes local recovery backups.")
                    Text("The integrity check detects corruption, not malicious changes. Backups support up to 256 MB and 100,000 transactions. Restoring replaces all transactions; merging is not supported.")
                }
            }
            .font(.footnote)
        }
        .expenseScreenChrome()
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isBusy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).disabled(isBusy)
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: LedgerBackupDocument.contentType,
                      defaultFilename: "Expenso-\(Money.day(Date()))") { result in
            switch result {
            case .success: status = "Backup saved. Keep it in a private location."
            case .failure(let error): errorMessage = error.localizedDescription
            }
            document = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: LedgerBackupDocument.readableContentTypes) { result in
            switch result {
            case .success(let url): inspect(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog("Replace the Entire Ledger?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Replace Ledger", role: .destructive) { restore() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This replaces every current transaction and all category settings with the selected backup. A local recovery backup is created first. This operation is not a merge.") }
        .alert("Backup & Restore", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onDisappear { work?.cancel() }
        }
        .interactiveDismissDisabled(isBusy)
    }

    private func createBackup() {
        begin {
            let snapshot = try LedgerBackupService.capture(context: context)
            let data = try await LedgerBackupIO.shared.encode(snapshot)
            try Task.checkCancellation()
            document = LedgerBackupDocument(data: data)
            exporting = true
        }
    }

    private func exportRecovery() {
        begin {
            guard let url = try LedgerBackupService.latestRecovery() else { throw LedgerBackupError.invalidFile }
            let payload = try await LedgerBackupIO.shared.read(url)
            let data = try await LedgerBackupIO.shared.encode(payload)
            try Task.checkCancellation()
            document = LedgerBackupDocument(data: data)
            exporting = true
        }
    }

    private func inspect(_ url: URL) {
        begin {
            let payload = try await LedgerBackupIO.shared.read(url)
            try Task.checkCancellation()
            let current = try LedgerBackupService.capture(context: context)
            preview = RestorePreview(payload: payload, currentCount: current.records.count)
        }
    }

    private func restore() {
        guard let preview else { return }
        begin {
            try await LedgerBackupService.restore(preview.payload, context: context)
            self.preview = nil
            // Rebuild tabs/sheets after merge so no stale managed object or answer remains.
            ledgerMutations.didRestoreLedger()
        }
    }

    private func begin(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        work?.cancel()
        status = nil
        errorMessage = nil
        isBusy = true
        work = Task { @MainActor in
            defer { isBusy = false }
            do { try await operation() }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
