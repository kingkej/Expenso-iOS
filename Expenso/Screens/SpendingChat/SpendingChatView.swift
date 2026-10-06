import SwiftUI
import CoreData

struct SpendingChatView: View {
    var body: some View {
        if #available(iOS 26, *) {
            RemoteSpendingChatView()
        } else {
            NavigationStack {
                ScrollView {
                    ContentUnavailableView("Spending Chat", systemImage: "bubble.left.and.bubble.right",
                        description: Text("Spending chat requires iOS 26 or later. Your dashboard remains available."))
                }
                .expenseScreenChrome()
                .navigationTitle("Chat")
            }
        }
    }
}

@available(iOS 26, *)
private struct RemoteSpendingChatView: View {
    private enum Sheet: String, Identifiable {
        case privacy, settings, history
        var id: String { rawValue }
    }
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = SpendingChatModel()
    @State private var question = ""
    @State private var sheet: Sheet?
    @State private var settings = OpenRouterSettings.shared
    @State private var confirmNewChat = false
    @State private var followsBottom = true
    @FocusState private var composerFocused: Bool
    private let bottomID = "chat-bottom"
    private let suggestions = [
        "How much did I spend this month?",
        "Compare my food spending this month and last month.",
        "What were my biggest expenses this month?"
    ]

    var body: some View {
        NavigationStack {
            Group {
                if let reason = model.unavailableReason {
                    ScrollView {
                        ContentUnavailableView {
                            Label("Set Up Spending Chat", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text(reason)
                        } actions: {
                            Button("Open Settings", systemImage: "gearshape") { composerFocused = false; sheet = .settings }
                                .primaryActionStyle()
                            if settings.provider == .onDevice {
                                Button("Check Again", systemImage: "arrow.clockwise") { model.refreshAvailability() }
                            }
                        }
                    }
                } else {
                    conversation
                        .expenseBottomBar { composer }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .expenseScreenChrome(bottom: model.unavailableReason != nil)
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Chat History", systemImage: "clock.arrow.circlepath") {
                            composerFocused = false
                            sheet = .history
                        }
                        Button("Privacy", systemImage: "lock.shield") { composerFocused = false; sheet = .privacy }
                    } label: { Label("Chat Options", systemImage: "ellipsis") }
                    .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat", systemImage: "square.and.pencil") { composerFocused = false; confirmNewChat = true }
                        .labelStyle(.iconOnly)
                        .disabled(model.messages.isEmpty && !model.isGenerating)
                }
            }
            .sheet(item: $sheet) { destination in
                Group {
                    switch destination {
                    case .privacy: ChatPrivacyView()
                    case .settings: ExpenseSettingsView()
                    case .history: SpendingChatHistoryView(model: model)
                    }
                }.expenseSheetStyle(.editor)
            }
            .confirmationDialog("Start a new chat?", isPresented: $confirmNewChat, titleVisibility: .visible) {
                Button("New Chat") {
                    if model.newChat() { question = "" }
                }
            } message: {
                Text("This conversation stays in Chat History. Your transactions aren't changed.")
            }
        }
        .task { model.configure(context: context) }
        .onChange(of: settings.revision) { model.settingsChanged() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { model.refreshAvailability() }
            if scenePhase == .background { model.stop() }
        }
        .onDisappear { model.stop() }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if model.messages.isEmpty { introduction }
                    if let error = model.historyStore.errorMessage ?? model.historyNotice {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(model.historyStore.errorMessage == nil ? "Chat History" : "Chat history wasn't saved",
                                  systemImage: model.historyStore.errorMessage == nil ? "info.circle" : "exclamationmark.triangle")
                            Text(error).font(.footnote)
                            Button("Retry", systemImage: "arrow.clockwise") { model.retryHistorySave() }
                        }
                        .foregroundStyle(.secondary).padding(16)
                    }
                    ForEach(model.messages) { message in
                        ChatMessageView(message: message)
                    }
                    if model.isGenerating {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Thinking", systemImage: "sparkles")
                                .font(.caption).foregroundStyle(.secondary)
                            if model.draftResponse.isEmpty || model.currentReports.isEmpty {
                                ProgressView().accessibilityLabel("Preparing answer")
                            } else {
                                Text(model.draftResponse).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height) < 100
            } action: { _, nearBottom in
                followsBottom = nearBottom
            }
            .onChange(of: model.messages.count) {
                followsBottom = true
                if reduceMotion {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: model.draftResponse) {
                if followsBottom { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Understand your spending").font(.title2.bold())
                Text(settings.provider == .openRouter
                    ? "Ask about your spending, spot patterns and compare months."
                    : "Ask about your transactions in English. Everything is processed on this device.")
                    .foregroundStyle(.secondary)
                Label(settings.provider == .openRouter ? "OpenRouter • Read-only" : "On-device • Read-only", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        submit(suggestion)
                    } label: {
                        HStack(alignment: .top) {
                            Text(suggestion).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isGenerating)
                }
            }
            Text("AI can make mistakes. Check the supporting figures below each answer.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about your spending", text: $question, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    .disabled(model.isGenerating)
                    .accessibilityLabel("Spending question")
                if model.isGenerating {
                    Button("Stop", systemImage: "stop.fill") { model.stop() }
                        .labelStyle(.iconOnly).primaryActionStyle()
                } else {
                    Button("Send", systemImage: "arrow.up") { submit(question) }
                        .labelStyle(.iconOnly).primaryActionStyle()
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.count > 1_000 || question.utf8.count > 4_000)
                }
            }
            if question.count > 1_000 || question.utf8.count > 4_000 {
                Text("Your question is too long. Try a shorter question.").font(.caption).foregroundStyle(.red)
            } else {
                Text(settings.provider == .openRouter ? "OpenRouter AI • History saved on this device" : "On-device AI • History saved on this device")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func submit(_ text: String) {
        guard !model.isGenerating, text.count <= 1_000, text.utf8.count <= 4_000 else { return }
        model.send(text)
        if model.isGenerating {
            question = ""
            composerFocused = false
        }
    }
}

struct ChatMessageView: View {
    @Environment(\.appAccentColor) private var accentColor
    let message: SpendingChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message.role == .user ? "You" : message.role == .assistant ? "Expenso" : message.role == .clarification ? "Clarification" : "Chat",
                systemImage: message.role == .user ? "person" : message.role == .assistant ? "sparkles" : "info.circle")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(message.reports) { evidence in
                SpendingEvidenceView(report: evidence.report)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? accentColor.opacity(0.1) : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct SpendingEvidenceView: View {
    @AppStorage(CategoryCatalog.storageKey) private var categoryData = Data()
    @Environment(\.appAccentColor) private var accentColor
    let report: SpendingReport

    var body: some View {
        let names = Dictionary(uniqueKeysWithValues: CategoryCatalog.decode(categoryData).map { ($0.id, $0.name) })
        VStack(alignment: .leading, spacing: 8) {
            Label("Supporting figures", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
            Text(report.selectionCount.map { "Selected \($0) transactions" } ?? report.rangeLabel)
                .font(.caption).foregroundStyle(.secondary)
            if report.selectionCount != nil {
                Text(report.rangeLabel).font(.caption).foregroundStyle(.secondary)
                Text("AI-selected transactions only. This may not include every matching expense or the full period.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("\(names[report.category] ?? report.categoryLabel) • \(report.kind.capitalized) • \(report.matchingCount) transactions")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Income", value: report.totalIncome + " " + report.currency)
            LabeledContent("Expenses", value: report.totalExpense + " " + report.currency)
            LabeledContent("Net", value: report.netBalance + " " + report.currency)
            if let count = report.estimatedConversionCount, count > 0 {
                Label("Includes \(count) estimated currency conversion\(count == 1 ? "" : "s").", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if report.excludedUnknownTypeCount + report.excludedInvalidAmountCount > 0 {
                Text("\(report.excludedUnknownTypeCount + report.excludedInvalidAmountCount) transactions were excluded because their amount or type could not be read.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 8) {
                    if let type = report.spendingType {
                        Text("Spending type: \(type)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !report.titleSearch.isEmpty {
                        Text(report.titleSearchTerms.count > 1
                             ? "Title matches any word: \(report.titleSearchTerms.joined(separator: ", "))"
                             : "Title contains: \(report.titleSearch)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !report.categories.isEmpty {
                        DisclosureGroup("Category Totals") {
                            ForEach(report.categories, id: \.category) { category in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(names[category.category] ?? (category.category == "unknown" ? "Unknown category" : category.category))
                                        .font(.subheadline)
                                    Text("\(category.count) transactions • Income \(category.income) \(report.currency) • Expenses \(category.expense) \(report.currency)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    if let types = report.spendingTypes, !types.isEmpty {
                        DisclosureGroup("Spending Types") {
                            ForEach(types, id: \.label) { type in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(type.label)
                                    Text("\(type.count) expenses • \(type.expense) \(report.currency)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                            Text("Types are AI suggestions or manual labels, not verified facts. Unclassified includes missing or stale labels.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if !report.topTransactions.isEmpty {
                        DisclosureGroup("Largest Matching Transactions") {
                            ForEach(report.topTransactions, id: \.id) { transaction in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(transaction.untrustedTitle.isEmpty ? "Untitled" : transaction.untrustedTitle)
                                        .font(.subheadline)
                                    Text("\(transaction.type.capitalized) • \(transaction.originalAmount) \(transaction.originalCurrency)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if transaction.originalCurrency != report.currency {
                                        Text("In \(report.currency): \(transaction.amount) • Rate date: \(transaction.rateDate ?? "Unavailable")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    Text("Calculated from local records when this answer was generated, using each transaction's locked daily rate in \(report.currency).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote).monospacedDigit()
        .padding(12)
        .background(accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ChatPrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ExpenseForm {
                Section("Apple Intelligence") {
                    Text("When Apple Intelligence is selected, chat questions and spending queries stay on this device. This chat provider makes no remote AI requests and needs no API key. Expenso never automatically falls back to OpenRouter. Optional AI Spending Types has a separate OpenRouter opt-in in Settings.")
                }
                Section("Remote AI") {
                    Label("OpenRouter + selected model provider", systemImage: "network")
                    Text("Only when OpenRouter is selected and processing is allowed: your questions, recent chat text and a preview of up to 120 recent transactions from the last 32 days are sent off-device when you send a message. The model can request category names, saved spending types, more reports and transaction pages. Providers may process or retain this data under their policies. Expenso requests providers that disallow data collection; this is not a zero-retention guarantee.")
                    Text("If you add an API key, it stays in this device's Keychain and is sent only to OpenRouter for authentication. OpenRouter requests use your account credits. Manage the provider or remove the key in Settings → AI → AI Provider.")
                }
                Section("Read-Only Access") {
                    Text("The assistant can query totals and inspect pages of up to \(SpendingInvestigationLimits.pageSize) transactions, including titles, dates, categories, currencies, amounts and saved spending types. It can request multiple pages, potentially covering the requested ledger scope. Notes and receipt images are not sent by chat. It cannot change, delete or export transactions. AI-selected records are not verified classifications; review the Supporting figures evidence.")
                }
                Section("Conversation") {
                    Text("Chat conversations and their Supporting figures snapshots are saved on this device, separately from your ledger. You can search, reopen or delete them in Chat History. They aren't synced or included in Expenso ledger backups. New Chat keeps the previous conversation. Deleting a chat doesn't delete your transactions or copies already sent to providers. Opening history sends nothing to AI; continuing an OpenRouter chat sends recent text only when you submit a new question. Figures in older answers remain snapshots. Stopping cannot retract a request already sent or guarantee it won't be billed.")
                }
                Section("Optional Spending Types") {
                    Text("AI Spending Types is off by default and separately enabled in Settings. It sends expense titles and category names to OpenRouter for the initial pass, then new or edited expenses at most daily when the app is opened. Amounts, notes and receipts are not sent. Saved types can be used by either chat provider; they may be wrong and can be corrected locally. Disable classification in Settings to stop future runs.")
                }
                Section("Receipts and Banking Screenshots") {
                    Text("With OpenRouter selected, image import uses Gemini 2.5 Flash independently of your chat model. You preview and explicitly approve each image upload. The visible image—including names, balances or account information—can be processed by OpenRouter and its provider. Crop sensitive information first. Image analysis uses your credits and is not a zero-retention guarantee. Each detected transaction needs your review and a separate save; nothing is saved automatically. Apple Intelligence keeps the existing on-device receipt path.")
                }
                Section("Accuracy") {
                    Text("Supporting figures are calculated by the app, not the language model. AI explanations may be wrong. Use this for understanding recorded spending, not professional financial advice.")
                }
            }
            .expenseScreenChrome()
            .navigationTitle("Chat Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
        }
    }
}
