import SwiftUI

@available(iOS 26, *)
struct SpendingChatHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let model: SpendingChatModel
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var selected: SavedSpendingConversation?
    @State private var pendingDelete: SavedSpendingConversation?
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let selected {
                    savedConversation(selected)
                } else {
                    historyList
                }
            }
            .navigationTitle(selected == nil ? "Chat History" : "Saved Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selected != nil {
                        Button("Back", systemImage: "chevron.left") { searchFocused = false; selected = nil }
                    } else {
                        Button("Close", systemImage: "xmark") { searchFocused = false; dismiss() }
                    }
                }
                if let selected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Delete Chat", systemImage: "trash", role: .destructive) { pendingDelete = selected }
                    }
                }
            }
            .confirmationDialog("Delete this chat?", item: $pendingDelete, titleVisibility: .visible) { conversation in
                Button("Delete Chat", role: .destructive) {
                    if model.deleteConversation(conversation.id) {
                        if selected?.id == conversation.id { selected = nil }
                    }
                }
            } message: { _ in
                Text("This removes the local conversation and its saved figures, not your transactions or copies already sent to AI providers.")
            }
            .expenseBottomBar { footer }
            .expenseScreenChrome(bottom: selected == nil)
        }
    }

    private var historyList: some View {
        List {
            if historyError != nil {
                Section { historyErrorContent }
            }
            Section {
                if model.historyStore.matching(search).isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Saved Chats" : "No Matching Chats",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(search.isEmpty ? "Your conversations appear here when you ask a question." : "Try a word from a question or answer."))
                }
                ForEach(model.historyStore.matching(search)) { conversation in
                    Button {
                        searchFocused = false
                        selected = conversation
                        actionError = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(conversation.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                            Text(conversation.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Text(conversation.provider.title)
                                Spacer()
                                Text(conversation.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash") { pendingDelete = conversation }
                            .tint(.red)
                    }
                }
            } footer: {
                Text("Saved on this device. Older figures reflect when the answer was written. Chats are not included in backups.")
            }
        }
        .searchable(text: $search, prompt: "Search questions and answers")
        .searchFocused($searchFocused)
        .scrollDismissesKeyboard(.interactively)
    }

    private func savedConversation(_ conversation: SavedSpendingConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        historyErrorContent
                        VStack(alignment: .leading, spacing: 8) {
                            Label(conversation.provider.title, systemImage: "bubble.left.and.bubble.right")
                            Text(conversation.updatedAt, format: .dateTime.year().month().day().hour().minute())
                            Text("Saved answers and figures reflect the records when they were generated. A new question queries your current transactions.")
                            if conversation.provider != OpenRouterSettings.shared.provider {
                                Text("Select \(conversation.provider.title) in AI Settings to continue this chat.")
                            }
                        }.font(.footnote).foregroundStyle(.secondary)
                    }
                    .id("saved-chat-status")
                    ForEach(conversation.messages) { ChatMessageView(message: $0) }
                }.padding(16)
            }
            .onChange(of: historyError) { _, error in
                if error != nil { proxy.scrollTo("saved-chat-status", anchor: .top) }
            }
        }
    }

    private var historyError: String? {
        actionError ?? model.historyStore.errorMessage ?? model.historyNotice
    }

    @ViewBuilder private var historyErrorContent: some View {
        if let error = historyError {
            VStack(alignment: .leading, spacing: 6) {
                Text(error).font(.footnote).fixedSize(horizontal: false, vertical: true)
                Button("Retry Saving", systemImage: "arrow.clockwise") {
                    actionError = nil
                    model.retryHistorySave()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var footer: some View {
        if let conversation = selected {
            VStack {
                Button("Continue Chat", systemImage: "bubble.left.and.text.bubble.right") {
                    if model.resume(conversation) { dismiss() }
                    else { actionError = model.historyStore.errorMessage ?? "This chat couldn't be reopened. Try opening it again from history." }
                }
                .primaryActionStyle()
                .disabled(conversation.provider != OpenRouterSettings.shared.provider)
            }
            .padding().frame(maxWidth: .infinity)
        }
    }
}
