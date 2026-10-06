import SwiftUI

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = OpenRouterSettings.shared
    @State private var key = ""
    @State private var selectedModel: String
    @State private var consent: Bool
    @State private var provider: OpenRouterSettings.Provider
    @State private var models: [OpenRouterModel] = []
    @State private var loadingModels = false
    @State private var showModels = false
    @State private var showAdvanced = false
    @State private var error: String?
    @State private var catalogueError: String?
    @FocusState private var keyFocused: Bool

    init() {
        selectedModel = OpenRouterSettings.shared.modelID
        consent = OpenRouterSettings.shared.allowsRemoteData && OpenRouterSettings.shared.allowsLedgerExploration
        provider = OpenRouterSettings.shared.provider
    }

    private let recommendedIDs = [OpenRouterClient.defaultModelID,
        "openai/gpt-4.1-mini", "openai/gpt-4.1-nano", "google/gemini-2.5-flash",
        "anthropic/claude-haiku-4.5", "deepseek/deepseek-chat-v3.1"]

    private var menuModels: [OpenRouterModel] {
        models.filter { recommendedIDs.contains($0.id) || $0.id == selectedModel }
            .sorted { first, second in
                if first.id == OpenRouterClient.defaultModelID { return true }
                if second.id == OpenRouterClient.defaultModelID { return false }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            ExpenseForm {
                Section {
                    ExpenseValueRow(title: "Provider") {
                        Picker("Provider", selection: $provider) {
                            ForEach(OpenRouterSettings.Provider.allCases) { provider in
                                Text(provider.title).tag(provider)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        .simultaneousGesture(TapGesture().onEnded { keyFocused = false })
                    }
                    DisclosureGroup("About providers") {
                        Text("Apple Intelligence keeps chat and receipt scanning on this device. OpenRouter sends approved data to online AI using your account credits. Switching starts a new chat and keeps the previous one in Chat History. Providers never switch automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("AI Provider") }

                if provider == .openRouter {
                    Section {
                        Label(settings.hasKey ? "API key saved" : "Connect your OpenRouter account", systemImage: "key")
                        ExpenseField(title: "API Key") {
                            SecureField(settings.hasKey ? "Replace key (optional)" : "Paste OpenRouter API key", text: $key)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .privacySensitive().focused($keyFocused)
                        }
                        Link("Get an OpenRouter Key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                            .simultaneousGesture(TapGesture().onEnded { keyFocused = false })
                    } header: { Text("Account") } footer: {
                        Text("Your key is stored securely on this device. Saving it does not send transactions or enable AI processing.")
                    }

                    Section {
                        Toggle("Allow OpenRouter Processing", isOn: $consent)
                        Text("Sends your questions, recent chat and requested transaction details to OpenRouter and its model provider. Requests use your account credits. Providers may retain this data.")
                            .font(.footnote)
                        DisclosureGroup("What is shared") {
                            Text("Chat starts with a preview of recent transactions and can request more reports and transaction pages across the scope of your question. This includes titles, dates, categories, spending types, currencies and amounts. Notes and receipt images are not sent by chat. Chat cannot change transactions.")
                            Text("Tapping Analyze sends your import text or image and category names to OpenRouter. Images may include names, balances and account details. Crop sensitive information before analyzing an image.")
                            Text("Expenso requests providers that disallow data collection. This is not a zero-retention guarantee; OpenRouter and provider policies still apply.")
                            Link("OpenRouter Privacy Policy", destination: URL(string: "https://openrouter.ai/privacy")!)
                        }.font(.footnote)
                        if !consent {
                            Text("Online chat and text/image import are off.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text("Privacy & Processing") }

                    Section {
                        DisclosureGroup("Advanced AI options", isExpanded: $showAdvanced) {
                            ExpenseValueRow(title: "Chat Model") {
                                Picker("Chat Model", selection: $selectedModel) {
                                    if !menuModels.contains(where: { $0.id == selectedModel }) {
                                        Text(selectedModel == OpenRouterClient.defaultModelID ? "GPT-5 mini · Default" : selectedModel).tag(selectedModel)
                                    }
                                    ForEach(menuModels) { model in
                                        Text(model.id == OpenRouterClient.defaultModelID ? model.name + " · Default" : model.name).tag(model.id)
                                    }
                                }
                                .labelsHidden().pickerStyle(.menu)
                                .simultaneousGesture(TapGesture().onEnded { keyFocused = false })
                            }
                            if let selected = models.first(where: { $0.id == selectedModel }) {
                                Text(selected.priceLabel).font(.footnote).foregroundStyle(.secondary)
                            }
                            Button("Browse All Models", systemImage: "list.bullet") { keyFocused = false; showModels = true }
                                .disabled(models.isEmpty)
                            if loadingModels { ProgressView("Loading models…") }
                            if let catalogueError {
                                Text(catalogueError).font(.footnote).foregroundStyle(.secondary)
                                Button("Retry Model List") { Task { await loadModels() } }
                            }
                            Text("Only models that support transaction queries are listed. GPT-5 models use medium reasoning effort. Prices may change. Your selected model is never replaced automatically.")
                                .font(.footnote).foregroundStyle(.secondary)
                            ExpenseValueRow(title: "Image Model") { Text("Gemini 2.5 Flash") }
                            Text("Image import uses this model independently of chat. Analyze starts the upload; review each detected transaction before saving.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                }

                Section("Spending Types") {
                    Text("Automatic spending suggestions have a separate opt-in in Settings → AI → AI Spending Types.")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("How this setting works") {
                        Text("Spending Types can use OpenRouter even while chat uses Apple Intelligence. Changing the chat provider does not change that opt-in. Removing your API key prevents future OpenRouter requests.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if settings.hasKey {
                    Section {
                        Button("Use Apple Intelligence") { keyFocused = false; disable(removeKey: false) }
                        Button("Remove API Key", role: .destructive) { keyFocused = false; disable(removeKey: true) }
                    }

                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .scrollDismissesKeyboard(.interactively)
            .expenseScreenChrome()
            .navigationTitle("AI Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { keyFocused = false; key = ""; dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(provider == .openRouter && !settings.hasKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showModels) {
                OpenRouterModelPicker(models: models, selection: $selectedModel).expenseSheetStyle(.editor)
            }
            .task(id: showAdvanced && provider == .openRouter) {
                if showAdvanced && provider == .openRouter { await loadModels() }
            }
            .onChange(of: provider) { _, _ in keyFocused = false }
            .onChange(of: showAdvanced) { _, _ in keyFocused = false }
            .onDisappear { key = "" }
        }
    }

    private func save() {
        keyFocused = false
        do {
            try settings.save(key: provider == .openRouter ? key : "", model: selectedModel, consent: consent, provider: provider)
            key = ""
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func disable(removeKey: Bool) {
        do {
            try settings.disable(removeKey: removeKey)
            key = ""
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func loadModels() async {
        guard !loadingModels else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            let result = try await OpenRouterClient.shared.models()
            try Task.checkCancellation()
            models = result
            catalogueError = nil
        } catch {
            guard !Task.isCancelled else { return }
            catalogueError = "Couldn't load current models. Your selected model is unchanged; try again when connected."
        }
    }
}

private struct OpenRouterModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    let models: [OpenRouterModel]
    @Binding var selection: String
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [OpenRouterModel] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? models : models.filter {
            $0.name.localizedStandardContains(text) || $0.id.localizedStandardContains(text)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { model in
                Button {
                    searchFocused = false
                    selection = model.id
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name).foregroundStyle(.primary)
                            Text(model.priceLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == model.id { Image(systemName: "checkmark") }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search models")
            .searchFocused($searchFocused)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden).expenseScreenChrome()
            .navigationTitle("Models").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { searchFocused = false; dismiss() }.labelStyle(.iconOnly)
                }
            }
        }
    }
}
