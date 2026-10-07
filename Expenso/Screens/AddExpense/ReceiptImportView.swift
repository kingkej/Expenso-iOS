import SwiftUI
import PhotosUI
import VisionKit
import AVFoundation
import Observation
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable
final class ReceiptImportModel {
    private(set) var preparedImage: Data?
    private(set) var remoteResult: RemoteImageTransactions?
    private(set) var isReading = false
    var error: String? { didSet { recoveryMessage = nil } }
    var recoveryMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    func recordError(_ failure: Error) {
        error = failure.localizedDescription
        if let failure = failure as? ReceiptScanError {
            recoveryMessage = failure.localizedDescription
        } else if let failure = failure as? OpenRouterError {
            switch failure {
            case .unfinished, .outputLimit:
                recoveryMessage = "The model couldn't finish. Try a smaller input or choose another model."
            default: recoveryMessage = failure.localizedDescription
            }
        } else if let failure = failure as? RemoteReceiptError {
            switch failure {
            case .invalidText, .tooManyTransactions:
                recoveryMessage = "Split the text into smaller batches and try again."
            default: recoveryMessage = failure.localizedDescription
            }
        }
    }

    func read(_ item: PhotosPickerItem, remotely: Bool, revision: UUID) {
        begin(remotely: remotely, revision: revision) {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ReceiptScanError.invalidImage }
            return data
        }
    }

    func read(_ image: UIImage, remotely: Bool, revision: UUID) {
        begin(remotely: remotely, revision: revision) {
            let encoding = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                guard let data = image.jpegData(compressionQuality: 0.9) else { throw ReceiptScanError.invalidImage }
                try Task.checkCancellation()
                return data
            }
            return try await withTaskCancellationHandler {
                try await encoding.value
            } onCancel: {
                encoding.cancel()
            }
        }
    }

    func read(_ provider: NSItemProvider, remotely: Bool, revision: UUID) {
        if provider.canLoadObject(ofClass: UIImage.self) {
            begin(remotely: remotely, revision: revision) {
                let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                    provider.loadObject(ofClass: UIImage.self) { object, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let image = object as? UIImage { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: ReceiptScanError.invalidImage) }
                    }
                }
                try Task.checkCancellation()
                let encoding = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    guard let data = image.jpegData(compressionQuality: 0.9) else { throw ReceiptScanError.invalidImage }
                    try Task.checkCancellation()
                    return data
                }
                return try await withTaskCancellationHandler {
                    try await encoding.value
                } onCancel: {
                    encoding.cancel()
                }
            }
            return
        }
        guard let type = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else { recordError(ReceiptScanError.invalidImage); return }
        begin(remotely: remotely, revision: revision) {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: ReceiptScanError.invalidImage) }
                }
            }
        }
    }

    func paste(_ providers: [NSItemProvider], remotely: Bool, revision: UUID,
               onText: @escaping @MainActor (String) -> Void) {
        guard !isReading else { return }
        if let image = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            read(image, remotely: remotely, revision: revision)
            return
        }
        let textProviders = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !textProviders.isEmpty else { return }
        cancel()
        error = nil
        let id = UUID()
        requestID = id
        isReading = true
        task = Task { [weak self] in
            do {
                var parts: [String] = []
                var byteCount = 0
                for provider in textProviders {
                    try Task.checkCancellation()
                    let part: String = try await withCheckedThrowingContinuation { continuation in
                        provider.loadObject(ofClass: NSString.self) { object, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let text = object as? String { continuation.resume(returning: text) }
                            else { continuation.resume(throwing: RemoteReceiptError.invalidText) }
                        }
                    }
                    byteCount += part.utf8.count + (parts.isEmpty ? 0 : 1)
                    guard byteCount <= 24_000 else { throw RemoteReceiptError.invalidText }
                    parts.append(part)
                }
                try Task.checkCancellation()
                guard let self, self.requestID == id, OpenRouterSettings.shared.revision == revision else { return }
                self.preparedImage = nil
                self.remoteResult = nil
                self.isReading = false
                self.task = nil
                onText(parts.joined(separator: "\n"))
            } catch {
                guard let self, self.requestID == id else { return }
                if !Task.isCancelled { self.recordError(error) }
                self.isReading = false
                self.task = nil
            }
        }
    }

    func analyzeText(_ text: String, categories: [ExpenseCategory]) {
        let settings = OpenRouterSettings.shared
        guard !isReading, settings.provider == .openRouter else { return }
        let key: String
        do { key = try settings.credentials() }
        catch { self.recordError(error); return }
        cancel()
        let id = UUID()
        let revision = settings.revision
        let selectedModel = settings.modelID
        requestID = id
        isReading = true
        error = nil
        remoteResult = nil
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self, self.requestID == id, settings.revision == revision,
                      settings.provider == .openRouter, settings.allowsRemoteData else { return }
                let result = try await RemoteReceiptInference.shared.extract(text: text, apiKey: key,
                    categories: categories, model: selectedModel)
                try Task.checkCancellation()
                guard self.requestID == id, settings.revision == revision,
                      settings.provider == .openRouter, settings.allowsRemoteData else { return }
                self.remoteResult = result
                self.isReading = false
                self.task = nil
            } catch {
                guard let self, self.requestID == id else { return }
                if !Task.isCancelled { self.recordError(error) }
                self.isReading = false
                self.task = nil
            }
        }
    }

    private func begin(remotely: Bool, revision: UUID, load: @escaping @MainActor () async throws -> Data) {
        cancel()
        let id = UUID()
        requestID = id
        isReading = true
        error = nil
        remoteResult = nil
        task = Task { [weak self] in
            do {
                let data = try await load()
                try Task.checkCancellation()
                if remotely {
                    let prepared = try await RemoteReceiptInference.shared.prepare(data: data)
                    try Task.checkCancellation()
                    guard let self, self.requestID == id, OpenRouterSettings.shared.revision == revision else { return }
                    self.preparedImage = prepared
                } else {
                    let payload = try await ReceiptScanner.shared.recognize(data: data)
                    let category = try await ReceiptInterpreter.suggestCategory(text: payload.extraction.rawText,
                        categories: CategoryCatalog.load())
                    try Task.checkCancellation()
                    guard let self, self.requestID == id, OpenRouterSettings.shared.revision == revision else { return }
                    let fields = payload.extraction
                    self.remoteResult = RemoteImageTransactions(imageData: payload.imageData,
                        transactions: [RemoteImageTransaction(title: fields.merchant,
                            amount: fields.amount.map(Money.string), currency: fields.currency,
                            date: fields.date, type: TRANS_TYPE_EXPENSE, category: category,
                            warnings: fields.warnings)], warnings: [])
                }
                guard let self, self.requestID == id else { return }
                self.isReading = false
                self.task = nil
            } catch {
                guard let self, self.requestID == id else { return }
                if !Task.isCancelled { self.recordError(error) }
                self.isReading = false
                self.task = nil
            }
        }
    }

    func analyze(categories: [ExpenseCategory]) {
        let settings = OpenRouterSettings.shared
        guard !isReading, settings.provider == .openRouter, let imageData = preparedImage else { return }
        let key: String
        do { key = try settings.credentials() }
        catch { self.recordError(error); return }
        cancel()
        let id = UUID()
        let revision = settings.revision
        requestID = id
        isReading = true
        error = nil
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self, self.requestID == id, settings.revision == revision,
                      settings.provider == .openRouter, settings.allowsRemoteData else { return }
                let result = try await RemoteReceiptInference.shared.extract(imageData: imageData,
                    apiKey: key, categories: categories)
                try Task.checkCancellation()
                guard self.requestID == id, settings.revision == revision,
                      settings.provider == .openRouter else { return }
                self.remoteResult = result
                self.isReading = false
                self.task = nil
            } catch {
                guard let self, self.requestID == id else { return }
                if !Task.isCancelled { self.recordError(error) }
                self.isReading = false
                self.task = nil
            }
        }
    }

    func reset() {
        cancel()
        preparedImage = nil
        remoteResult = nil
        error = nil
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
    @State private var settings = OpenRouterSettings.shared
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var scannedImage: UIImage?
    @State private var text = ""
    @State private var showAISettings = false
    @State private var inputFocused = false
    @State private var didImport = false
    @State private var cameraPermissionTask: Task<Void, Never>?

    private var hasInput: Bool {
        model.preparedImage != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canAnalyze: Bool {
        settings.provider == .openRouter && settings.hasKey && settings.allowsRemoteData
            && hasInput && text.utf8.count <= 24_000 && !model.isReading
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result = model.remoteResult {
                    RemoteTransactionReviewView(result: result, editor: editor,
                        onSaved: { didImport = true }, onFinished: finishImport)
                } else {
                    ExpenseForm {
                        Section {
                            if let data = model.preparedImage, let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .frame(height: 240)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .accessibilityLabel("Image to import")
                                Button("Remove Image", systemImage: "xmark.circle") { model.reset() }
                                    .disabled(model.isReading)
                            } else {
                                HStack(alignment: .bottom, spacing: 8) {
                                    ZStack(alignment: .topLeading) {
                                        if text.isEmpty {
                                            Text("Paste an image, or text for online AI")
                                                .foregroundStyle(.secondary)
                                                .padding(.top, 8).padding(.leading, 5)
                                                .allowsHitTesting(false)
                                        }
                                        ReceiptPasteEditor(text: Binding(get: { text }, set: { value in
                                            if model.error != nil || model.remoteResult != nil { model.reset() }
                                            text = value
                                        }), focused: $inputFocused, isEnabled: !model.isReading) { provider in
                                            guard !model.isReading else { return }
                                            inputFocused = false
                                            model.read(provider, remotely: settings.provider == .openRouter,
                                                revision: settings.revision)
                                        }
                                            .frame(height: 140)
                                    }
                                    attachmentMenu
                                }
                            }
                            if text.utf8.count > 24_000 {
                                Text("This text is too long. Split it into smaller batches.")
                                    .font(.footnote).foregroundStyle(.red)
                            }
                        }
                        if hasInput, !canAnalyze, !model.isReading, text.utf8.count <= 24_000 {
                            Section {
                                Button("Set Up Online Import", systemImage: "gearshape") { inputFocused = false; showAISettings = true }
                            }
                        }
                        if model.isReading {
                            Section {
                                VStack(spacing: 12) {
                                    ProgressView().progressViewStyle(.circular)
                                    Text("Processing…").font(.subheadline).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 20)
                            }
                        }
                        if let error = model.error {
                            Section {
                                Label(model.recoveryMessage ?? "Import couldn't finish. Check your input and try again.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                                DisclosureGroup("Details") { Text(error).font(.footnote).textSelection(.enabled) }
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .expenseScreenChrome(bottom: false)
                    .expenseBottomBar {
                        if model.isReading {
                            Button("Cancel", role: .cancel) { model.cancel() }
                                .accessibilityLabel("Cancel Processing")
                                .frame(maxWidth: .infinity)
                                .primaryActionStyle()
                                .padding(.horizontal, 20).padding(.vertical, 12)
                        } else if hasInput, settings.provider == .openRouter {
                            Button("Analyze", systemImage: "sparkles") {
                                guard canAnalyze else { return }
                                inputFocused = false
                                let categories = CategoryCatalog.decode(categoryData).filter { !$0.isArchived }
                                if model.preparedImage != nil { model.analyze(categories: categories) }
                                else { model.analyzeText(text, categories: categories) }
                            }
                            .frame(maxWidth: .infinity)
                            .primaryActionStyle().disabled(!canAnalyze)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                        }
                    }
                }
            }
            .navigationTitle(model.remoteResult != nil ? "Transactions" : "Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.remoteResult == nil {
                        Button("Cancel", systemImage: "xmark", action: finishImport).labelStyle(.iconOnly)
                    }
                }
            }
        }
        .sheet(isPresented: $showAISettings) { AISettingsView().expenseSheetStyle(.editor) }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .onChange(of: photo) {
            if let photo {
                model.read(photo, remotely: settings.provider == .openRouter, revision: settings.revision)
                self.photo = nil
            }
        }
        .onChange(of: model.preparedImage) {
            if model.preparedImage != nil { text = "" }
        }
        .onChange(of: settings.revision) {
            cameraPermissionTask?.cancel()
            showCamera = false
            showPhotos = false
            model.reset()
            model.error = "AI settings changed. Review your input before continuing."
            model.recoveryMessage = model.error
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            guard let image = scannedImage else { return }
            scannedImage = nil
            model.read(image, remotely: settings.provider == .openRouter, revision: settings.revision)
        }) {
            ReceiptDocumentCamera { result in
                switch result {
                case .success(let image):
                    scannedImage = image
                case .failure(let error): model.recordError(error)
                }
                showCamera = false
            } onCancel: { showCamera = false }
            .ignoresSafeArea()
        }
        .onDisappear { cameraPermissionTask?.cancel(); model.cancel() }
    }

    private var attachmentMenu: some View {
        Menu {
            Button("Scan Receipt", systemImage: "doc.viewfinder") {
                inputFocused = false
                cameraPermissionTask?.cancel()
                cameraPermissionTask = Task { await openCamera() }
            }
            .disabled(!VNDocumentCameraViewController.isSupported)
            Button("Choose Photo", systemImage: "photo") { inputFocused = false; showPhotos = true }
        } label: {
            Image(systemName: "paperclip").font(.title3)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Add Attachment")
        .disabled(model.isReading)
    }

    @MainActor private func openCamera() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized { showCamera = true }
        else if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            if granted { showCamera = true }
            else {
                model.error = "Camera access wasn't granted. You can choose a receipt image instead."
                model.recoveryMessage = model.error
            }
        } else {
            model.error = "Allow camera access in Settings to scan paper receipts, or choose a receipt image."
            model.recoveryMessage = model.error
        }
    }

    private func finishImport() {
        cameraPermissionTask?.cancel()
        model.cancel()
        if didImport, editor.isPristineDraft {
            editor.closePresenter = true
        }
        dismiss()
    }
}

/// UIKit's edit menu supports image providers as well as ordinary text insertion.
struct ReceiptPasteEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let isEnabled: Bool
    let onImagePaste: (NSItemProvider) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PasteTextView {
        let view = PasteTextView()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier, UTType.plainText.identifier])
        view.delegate = context.coordinator
        view.pasteDelegate = context.coordinator
        view.onImagePaste = { [weak coordinator = context.coordinator] provider in
            coordinator?.pasteImage(provider)
        }
        view.onClipboardImagePaste = { [weak coordinator = context.coordinator] image in
            guard let coordinator, coordinator.parent.isEnabled else { return }
            coordinator.textView?.resignFirstResponder()
            coordinator.parent.onImagePaste(NSItemProvider(object: image))
        }
        view.enableEmptyPasteMenu()
        view.accessibilityLabel = "Transactions to import"
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: PasteTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text, view.markedTextRange == nil { view.text = text }
        view.isEditable = isEnabled
        if !isEnabled { view.dismissEmptyPasteMenu() }
        if !focused, view.isFirstResponder { view.resignFirstResponder() }
    }

    final class PasteTextView: UITextView, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
        var onImagePaste: ((NSItemProvider) -> Void)?
        var onClipboardImagePaste: ((UIImage) -> Void)?
        private lazy var emptyPasteMenu = UIEditMenuInteraction(delegate: self)
        private weak var emptyPasteGesture: UITapGestureRecognizer?

        func enableEmptyPasteMenu() {
            addInteraction(emptyPasteMenu)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(showEmptyPasteMenu(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.cancelsTouchesInView = false
            doubleTap.delegate = self
            emptyPasteGesture = doubleTap
            addGestureRecognizer(doubleTap)
        }

        func dismissEmptyPasteMenu() { emptyPasteMenu.dismissMenu() }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === emptyPasteGesture else {
                return super.gestureRecognizerShouldBegin(gestureRecognizer)
            }
            return isEditable && text.isEmpty
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func showEmptyPasteMenu(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, isEditable, text.isEmpty,
                  canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil) else { return }
            becomeFirstResponder()
            emptyPasteMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
                sourcePoint: gesture.location(in: self)))
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                 menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard isEditable, text.isEmpty else { return nil }
            return importPasteMenu(suggestedActions: suggestedActions)
        }

        func importPasteMenu(suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard isEditable else { return nil }
            let paste = #selector(UIResponderStandardEditActions.paste(_:))
            func containsPaste(_ element: UIMenuElement) -> Bool {
                if let command = element as? UICommand { return command.action == paste }
                if let menu = element as? UIMenu { return menu.children.contains(where: containsPaste) }
                return false
            }
            // AutoFill can be suggested without Paste. Preserve system commands,
            // adding the standard responder action only when it is missing.
            guard canPerformAction(paste, withSender: nil), !suggestedActions.contains(where: containsPaste) else {
                return UIMenu(children: suggestedActions)
            }
            let command = UICommand(title: String(localized: "Paste"), action: paste)
            return UIMenu(children: [command] + suggestedActions)
        }

        private func imageProvider(in providers: [NSItemProvider]) -> NSItemProvider? {
            providers.first {
                $0.canLoadObject(ofClass: UIImage.self) || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            }
        }

        override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
            isEditable && (imageProvider(in: itemProviders) != nil || super.canPaste(itemProviders))
        }

        override func paste(itemProviders: [NSItemProvider]) {
            guard isEditable else { return }
            if let image = imageProvider(in: itemProviders) {
                onImagePaste?(image)
            } else {
                super.paste(itemProviders: itemProviders)
            }
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(UIResponderStandardEditActions.paste(_:)) {
                // Availability checks do not read clipboard contents or trigger
                // a paste permission prompt while UIKit builds the edit menu.
                return isEditable && (UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings
                    || super.canPerformAction(action, withSender: sender))
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            guard isEditable else { return }
            // Read providers only after the user chooses the native Paste action.
            // Plain UITextView's text-only paste path can reject image-only data.
            if let image = UIPasteboard.general.image {
                onClipboardImagePaste?(image)
                return
            }
            if UIPasteboard.general.hasImages,
               let image = UIPasteboard.general.itemProviders.first(where: {
                   $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
               }) {
                onImagePaste?(image)
                return
            }
            if let text = UIPasteboard.general.string {
                insertText(text)
                delegate?.textViewDidChange?(self)
                return
            }
            super.paste(sender)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var parent: ReceiptPasteEditor
        weak var textView: UITextView?
        init(parent: ReceiptPasteEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused { parent.focused = false }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            (textView as? PasteTextView)?.importPasteMenu(suggestedActions: suggestedActions)
        }

        @available(iOS 26.0, *)
        func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue],
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            (textView as? PasteTextView)?.importPasteMenu(suggestedActions: suggestedActions)
        }

        func pasteImage(_ provider: NSItemProvider) {
            guard parent.isEnabled else { return }
            textView?.resignFirstResponder()
            parent.onImagePaste(provider)
        }

        func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
                                              transform item: UITextPasteItem) {
            guard parent.isEnabled else { item.setNoResult(); return }
            if item.itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                item.setNoResult()
                pasteImage(item.itemProvider)
            } else {
                item.setDefaultResult()
            }
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
