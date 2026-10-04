import SwiftUI
import PhotosUI
import VisionKit
import AVFoundation
import Observation
import UIKit

@MainActor @Observable
private final class ReceiptImportModel {
    private(set) var payload: ReceiptScanPayload?
    private(set) var isReading = false
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    func read(_ item: PhotosPickerItem) {
        begin {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ReceiptScanError.invalidImage }
            return data
        }
    }

    func read(_ image: UIImage) {
        // UIImage remains UI-actor confined; the recognizer receives only bytes.
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            error = ReceiptScanError.invalidImage.localizedDescription
            return
        }
        begin { data }
    }

    private func begin(load: @escaping @MainActor () async throws -> Data) {
        cancel()
        let id = UUID()
        requestID = id
        isReading = true
        error = nil
        payload = nil
        task = Task { [weak self] in
            do {
                let data = try await load()
                try Task.checkCancellation()
                let payload = try await ReceiptScanner.shared.recognize(data: data)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.payload = payload
                self.isReading = false
                self.task = nil
            } catch {
                guard let self, self.requestID == id else { return }
                if !Task.isCancelled { self.error = error.localizedDescription }
                self.isReading = false
                self.task = nil
            }
        }
    }

    func cancel() {
        requestID = nil
        task?.cancel()
        task = nil
        isReading = false
    }
}

/// All suggestions stay in this local draft until the user explicitly applies them.
struct ReceiptImportView: View {
    @ObservedObject var editor: AddExpenseViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var model = ReceiptImportModel()
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var review: ReceiptReviewDraft?
    @State private var cameraPermissionTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let review {
                    ReceiptReviewForm(draft: review, editor: editor)
                } else {
                    Form {
                        Section {
                            Button("Scan Paper Receipt", systemImage: "doc.viewfinder") {
                                cameraPermissionTask?.cancel()
                                cameraPermissionTask = Task { await openCamera() }
                            }
                            .disabled(!VNDocumentCameraViewController.isSupported || model.isReading)
                            Button("Choose Receipt Image", systemImage: "photo") { showPhotos = true }
                                .disabled(model.isReading)
                        } footer: {
                            Text("Scan one page per receipt, or choose a photo or screenshot. Text is read on this device. No receipt is uploaded.")
                        }
                        if model.isReading {
                            Section { ProgressView("Reading receipt on this device…") }
                        }
                        if let error = model.error {
                            Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                        }
                        Section {
                            Text("Apple Intelligence interprets receipt text without store templates or fixed total labels when available. Merchant, total, currency, and date are suggestions only; unclear fields need your review. Item lines are not added together.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(review == nil ? "Scan Receipt" : "Review Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { cameraPermissionTask?.cancel(); model.cancel(); dismiss() }.labelStyle(.iconOnly)
                }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .onChange(of: photo) {
            if let photo {
                model.read(photo)
                self.photo = nil // Permit retrying the same image after a load/OCR failure.
            }
        }
        .onChange(of: model.payload?.imageData) {
            if let payload = model.payload { review = ReceiptReviewDraft(payload: payload, editor: editor) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            ReceiptDocumentCamera { result in
                showCamera = false
                switch result {
                case .success(let image): model.read(image)
                case .failure(let error): model.error = error.localizedDescription
                }
            } onCancel: { showCamera = false }
            .ignoresSafeArea()
        }
        .onDisappear { cameraPermissionTask?.cancel(); model.cancel() }
    }

    @MainActor private func openCamera() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized { showCamera = true }
        else if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            if granted { showCamera = true }
            else { model.error = "Camera access wasn't granted. You can choose a receipt image instead." }
        } else { model.error = "Allow camera access in Settings to scan paper receipts, or choose a receipt image." }
    }
}

private struct ReceiptReviewDraft: Identifiable {
    let id = UUID()
    let payload: ReceiptScanPayload
    let title: String
    let amount: String
    let currency: String
    let date: Date
    let applyDate: Bool

    @MainActor init(payload: ReceiptScanPayload, editor: AddExpenseViewModel) {
        self.payload = payload
        title = payload.extraction.merchant ?? editor.title
        amount = payload.extraction.amount.map(Money.string) ?? ""
        currency = payload.extraction.currency ?? editor.currency
        date = payload.extraction.date ?? editor.occuredOn
        applyDate = payload.extraction.date != nil
    }
}

private struct ReceiptReviewForm: View {
    let draft: ReceiptReviewDraft
    @ObservedObject var editor: AddExpenseViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var amount: String
    @State private var currency: String
    @State private var date: Date
    @State private var applyDate: Bool
    @State private var attachImage = true
    @State private var type = TRANS_TYPE_EXPENSE
    @State private var showCurrencyPicker = false

    init(draft: ReceiptReviewDraft, editor: AddExpenseViewModel) {
        self.draft = draft
        self.editor = editor
        _title = State(initialValue: draft.title)
        _amount = State(initialValue: draft.amount)
        _currency = State(initialValue: draft.currency)
        _date = State(initialValue: draft.date)
        _applyDate = State(initialValue: draft.applyDate)
    }

    var body: some View {
        Form {
            Section {
                TextField("Merchant / Title", text: $title)
                TextField("Total", text: $amount).keyboardType(.decimalPad)
                Button { showCurrencyPicker = true } label: { LabeledContent("Currency", value: currency) }
                Picker("Type", selection: $type) {
                    Text("Expense").tag(TRANS_TYPE_EXPENSE)
                    Text("Income / Refund").tag(TRANS_TYPE_INCOME)
                }
                Toggle("Use receipt date", isOn: $applyDate)
                if applyDate { DatePicker("Date", selection: $date, displayedComponents: .date) }
                Toggle("Attach receipt image", isOn: $attachImage)
            } header: { Text("Check Every Field") } footer: {
                Text("Currency defaults to your current transaction currency when it cannot be detected. Category and notes stay unchanged. A selected receipt date replaces the transaction date; an attached receipt replaces the current image.")
            }
            if !draft.payload.extraction.warnings.isEmpty {
                Section("Needs Review") {
                    ForEach(draft.payload.extraction.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.footnote)
                    }
                }
            }
            Section("Receipt") {
                if let image = UIImage(data: draft.payload.imageData) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                }
                DisclosureGroup("Recognized Text") {
                    Text(draft.payload.extraction.rawText).font(.footnote).textSelection(.enabled)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button("Use Receipt", systemImage: "checkmark") {
                editor.applyReceipt(title: title, amount: amount, currency: currency,
                    date: applyDate ? date : nil, type: type,
                    image: attachImage ? UIImage(data: draft.payload.imageData) : nil)
                dismiss()
            }
            .primaryActionStyle()
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (try? Money.parse(amount)) == nil)
            .padding()
        }
        .sheet(isPresented: $showCurrencyPicker) {
            CurrencyPickerView(selection: $currency, title: "Receipt Currency").expenseSheetStyle()
        }
    }
}

private struct ReceiptDocumentCamera: UIViewControllerRepresentable {
    let onScan: (Result<UIImage, Error>) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) { }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: ReceiptDocumentCamera
        init(parent: ReceiptDocumentCamera) { self.parent = parent }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount == 1 else { parent.onScan(.failure(ReceiptScanError.onePageOnly)); return }
            parent.onScan(.success(scan.imageOfPage(at: 0)))
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.onCancel() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onScan(.failure(error))
        }
    }
}
