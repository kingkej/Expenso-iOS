import SwiftUI
import CoreData

struct SpendingChatView: View {
    var body: some View {
        if #available(iOS 26, *) {
            OnDeviceSpendingChatView()
        } else {
            NavigationStack {
                ContentUnavailableView("On-Device Chat", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Spending chat requires iOS 26 or later and Apple Intelligence. Your dashboard remains available."))
                    .navigationTitle("Chat")
            }
        }
    }
}

@available(iOS 26, *)
private struct OnDeviceSpendingChatView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = SpendingChatModel()
    @State private var question = ""
    @State private var showPrivacy = false
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
                    ContentUnavailableView {
                        Label("On-Device Chat Unavailable", systemImage: "apple.intelligence")
                    } description: {
                        Text(reason)
                    } actions: {
                        Button("Check Again", systemImage: "arrow.clockwise") { model.refreshAvailability() }
                            .primaryActionStyle()
                    }
                } else {
                    conversation
                        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Privacy", systemImage: "lock.shield") { showPrivacy = true }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat", systemImage: "square.and.pencil") { confirmNewChat = true }
                        .labelStyle(.iconOnly)
                        .disabled(model.messages.isEmpty && !model.isGenerating)
                }
            }
            .sheet(isPresented: $showPrivacy) { ChatPrivacyView().expenseSheetStyle() }
            .confirmationDialog("Start a new chat?", isPresented: $confirmNewChat, titleVisibility: .visible) {
                Button("Clear Chat", role: .destructive) {
                    model.newChat()
                    question = ""
                }
            } message: {
                Text("This clears this window's conversation, not your transactions.")
            }
        }
        .task { model.configure(context: context) }
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
                    ForEach(model.messages) { message in
                        ChatMessageView(message: message)
                    }
                    if model.isGenerating {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Reading your transactions", systemImage: "sparkles")
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
                Text("Ask about your transactions in English. Everything is processed on this device.")
                    .foregroundStyle(.secondary)
                Label("Private • Read-only", systemImage: "lock.shield")
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
            Text("AI explanations can be mistaken. Check the local figures below each answer. This isn't financial advice.")
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
                Text("Your question is too long. Keep it under 1,000 simple characters.").font(.caption).foregroundStyle(.red)
            } else {
                Text("On-device AI • Chat kept only in memory")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
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

private struct ChatMessageView: View {
    @Environment(\.appAccentColor) private var accentColor
    let message: SpendingChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message.role == .user ? "You" : message.role == .assistant ? "Expenso" : message.role == .clarification ? "Clarification • No figures queried" : "Chat",
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
    @Environment(\.appAccentColor) private var accentColor
    let report: SpendingReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local Figures", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
            Text(report.rangeLabel).font(.caption).foregroundStyle(.secondary)
            Text("\(report.categoryLabel) • \(report.kind.capitalized) • \(report.matchingCount) transactions")
                .font(.caption).foregroundStyle(.secondary)
            if !report.titleSearch.isEmpty {
                Text("Title contains: \(report.titleSearch)").font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Income", value: report.totalIncome + " " + report.currency)
            LabeledContent("Expenses", value: report.totalExpense + " " + report.currency)
            LabeledContent("Net", value: report.netBalance + " " + report.currency)
            if report.excludedUnknownTypeCount + report.excludedInvalidAmountCount > 0 {
                Text("Excluded \(report.excludedUnknownTypeCount) unknown-type and \(report.excludedInvalidAmountCount) invalid-amount records.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !report.categories.isEmpty {
                DisclosureGroup("Category Totals") {
                    ForEach(report.categories, id: \.category) { category in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(category.category == "unknown" ? "Unknown category" : getTransTagTitle(transTag: category.category))
                                .font(.subheadline)
                            Text("\(category.count) transactions • Income \(category.income) \(report.currency) • Expenses \(category.expense) \(report.currency)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
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
                                Text("In base: \(transaction.amount) \(report.currency) • Rate date: \(transaction.rateDate ?? "Unavailable")")
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
        .font(.footnote).monospacedDigit()
        .padding(12)
        .background(accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ChatPrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("On Your Device") {
                    Label("No remote AI service or API key", systemImage: "iphone")
                    Text("The Apple Intelligence model processes questions and selected transaction data locally.")
                }
                Section("Read-Only Access") {
                    Text("The assistant can query dates, categories, totals and a limited set of transaction titles. Notes and images aren't provided. It cannot change, delete or export your transactions.")
                }
                Section("Conversation") {
                    Text("Chat is kept only in memory for this window. New Chat clears it. Starting another question refreshes the transaction figures; older answers remain snapshots.")
                }
                Section("Accuracy") {
                    Text("Local Figures are calculated by the app, not the language model. AI explanations may be wrong. Use this for understanding recorded spending, not professional financial advice.")
                }
            }
            .scrollContentBackground(.hidden)
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
