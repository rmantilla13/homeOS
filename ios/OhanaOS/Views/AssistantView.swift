import SwiftUI

/// How the assistant screen was opened: with a suggested prompt, by voice, or blank.
struct AssistantLaunch: Identifiable {
    let id = UUID()
    var prompt: String?
    var listen = false
}

struct AssistantSuggestion: Identifiable {
    let title: String
    let icon: String
    let prompt: String
    var id: String { title }

    static let hero = [
        AssistantSuggestion(title: "Add activity", icon: "plus", prompt: "I'd like to add an activity to the calendar."),
        AssistantSuggestion(title: "Organize calendar", icon: "calendar", prompt: "What does our week look like? Anything I should plan around?"),
        AssistantSuggestion(title: "What's for dinner?", icon: "fork.knife", prompt: "What's for dinner tonight?"),
        AssistantSuggestion(title: "Grocery list", icon: "cart", prompt: "What's on our grocery list?"),
    ]

    static let more = hero + [
        AssistantSuggestion(title: "Who's busy today?", icon: "person.2", prompt: "Who has something on today?"),
        AssistantSuggestion(title: "Chores left", icon: "checkmark.circle", prompt: "Which chores are still left today?"),
    ]
}

/// Chat with the family assistant (the `assistant` edge function). Replies
/// stream in; conversations are kept as threads you can come back to.
struct AssistantView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let launch: AssistantLaunch

    @State private var draft = ""
    @State private var dictation = Dictation()
    @State private var didLaunch = false
    @State private var showingHistory = false
    /// A question waiting for the person to allow the AI assistant.
    @State private var consentQuestion: PendingQuestion?
    @FocusState private var focused: Bool

    private struct PendingQuestion: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if store.chat.isEmpty {
                            emptyState
                        }
                        ForEach(store.chat) { message in
                            Group {
                                if message.isStreaming && message.text.isEmpty {
                                    TypingIndicator()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    MessageBubble(message: message)
                                }
                            }
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity))
                        }
                        Color.clear.frame(height: 1).id(bottomId)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .readableColumn()
                    .animation(Theme.springy, value: store.chat.count)
                    .animation(.easeInOut(duration: 0.2), value: store.isThinking)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.chat.count) {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomId, anchor: .bottom) }
                }
                // Follow the reply as it streams in.
                .onChange(of: store.chat.last?.text) { proxy.scrollTo(bottomId, anchor: .bottom) }
            }
            inputBar.readableColumn()
        }
        .background {
            ZStack(alignment: .top) {
                Theme.background
                GlowView()
                    .frame(height: 320)
                    .offset(y: -190)
                    .opacity(0.7)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingHistory) { ThreadListView() }
        .sheet(item: $consentQuestion) { question in
            AIConsentSheet(onAllow: { answerConsent(true, to: question) },
                           onNotNow: { answerConsent(false, to: question) })
        }
        .task {
            guard !didLaunch else { return }
            didLaunch = true
            if let prompt = launch.prompt {
                // A suggestion chip starts its own conversation.
                store.newChat()
                submit(prompt)
            } else if launch.listen {
                await dictation.start()
            } else {
                #if DEBUG
                // Keep the keyboard down so the demo transcript shows in full.
                if DemoMode.isOn { return }
                #endif
                focused = true
            }
        }
        .task { await store.loadThreads() }
        .onChange(of: dictation.transcript) { _, text in
            if !text.isEmpty { draft = text }
        }
        .onDisappear { dictation.cancel() }
        // A full-screen cover: Home's error alert can't show over it.
        .showsStoreErrors()
        .alert("Voice", isPresented: Binding(
            get: { dictation.errorMessage != nil },
            set: { if !$0 { dictation.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictation.errorMessage ?? "")
        }
    }

    private let bottomId = "bottom"

    private var subtitle: String {
        if store.isThinking { return "Thinking…" }
        if store.isReplying { return "Answering…" }
        return store.currentThread?.title ?? "Family assistant"
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40)
                    .background(Theme.surface, in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 1) {
                Text("Ohana").font(.headline).foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button { showingHistory = true } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40)
                    .background(Theme.surface, in: Circle())
            }
            .accessibilityLabel("Chat history")
            Button {
                withAnimation(Theme.springy) { store.newChat() }
                focused = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40)
                    .background(Theme.surface, in: Circle())
            }
            .disabled(store.chat.isEmpty)
            .accessibilityLabel("New chat")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("HELLO \(firstName.uppercased())!")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.text.opacity(0.7))
                Text("How can I help you today?")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
                Text("Ask about the calendar, chores, meals or lists. I can add things for you too.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 24)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(AssistantSuggestion.more) { suggestion in
                    Button { submit(suggestion.prompt) } label: {
                        Chip(title: suggestion.title, icon: suggestion.icon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            if !store.threads.isEmpty {
                Button { showingHistory = true } label: {
                    Label("Earlier chats", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.pill(.soft))
            }
        }
        .padding(.top, 70)
        .transition(.opacity)
    }

    private var firstName: String {
        let name = store.myProfile?.displayName.nilIfEmpty ?? store.me?.displayName
        return name?.split(separator: " ").first.map(String.init) ?? "there"
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(dictation.isRecording ? "Listening…" : "Ask Ohana anything", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.divider, lineWidth: 1))

            Group {
                if dictation.isRecording {
                    CircleIconButton(systemName: "stop.fill", size: 48, tint: Theme.danger) { dictation.stop() }
                        .overlay(PulseRing())
                        .accessibilityLabel("Stop listening")
                } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    CircleIconButton(systemName: "mic.fill", size: 48) { Task { await dictation.start() } }
                        .accessibilityLabel("Speak")
                } else {
                    CircleIconButton(systemName: "arrow.up", size: 48) { send() }
                        .disabled(store.isReplying)
                        .accessibilityLabel("Send")
                }
            }
            .transition(.scale.combined(with: .opacity))
        }
        .animation(Theme.springy, value: dictation.isRecording)
        .animation(Theme.springy, value: draft.isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.isReplying else { return }
        dictation.cancel()
        dictation.transcript = ""
        draft = ""
        submit(text)
    }

    /// Every question goes through here: typed, dictated or a suggestion.
    /// Until the person allows the AI assistant on this iPhone, it asks first.
    private func submit(_ text: String) {
        guard store.hasAIConsent else {
            focused = false
            consentQuestion = PendingQuestion(text: text)
            return
        }
        Task { await store.ask(text) }
    }

    /// Allow sends the question. Not now sends nothing and leaves it in the box.
    private func answerConsent(_ allowed: Bool, to question: PendingQuestion) {
        consentQuestion = nil
        if allowed {
            store.allowAI()
            Task { await store.ask(question.text) }
        } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = question.text
        }
    }
}

/// Asked once per account on this iPhone, before a person's first question
/// goes to the assistant. Allow stores the answer; Not now sends nothing.
struct AIConsentSheet: View {
    let onAllow: () -> Void
    let onNotNow: () -> Void
    @Environment(\.mood) private var mood

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(mood.accent, in: Circle())
                        .accessibilityHidden(true)
                    Text("Before you ask Ohana")
                        .font(.system(size: 26, weight: .bold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.text)
                    Text("Ohana's assistant is AI. When you ask it something, your question and the family details it needs to answer (names, calendar, chores and points, rewards, meals, lists and family memory) are sent to Anthropic, which makes the Claude model, to write the reply. Nothing is sent until you allow it.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.muted)
                    Link("Privacy policy", destination: Config.privacyPolicyURL)
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 28)
                .padding(.top, 48)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 10) {
                Button(action: onAllow) {
                    HStack {
                        Spacer()
                        Text("Allow")
                        Spacer()
                    }
                }
                .buttonStyle(.pill())
                Button(action: onNotNow) {
                    HStack {
                        Spacer()
                        Text("Not now")
                        Spacer()
                    }
                }
                .buttonStyle(.pill(.soft))
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background {
            ZStack(alignment: .top) {
                Theme.background
                GlowView()
                    .frame(height: 260)
                    .offset(y: -150)
                    .opacity(0.7)
            }
            .ignoresSafeArea()
        }
        // Allow or Not now: swiping it away would leave the question unanswered.
        .interactiveDismissDisabled()
    }
}

/// Your earlier conversations: tap to reopen, swipe to delete.
struct ThreadListView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.threads.isEmpty {
                    Text("No conversations yet. Ask Ohana something and it'll show up here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .listRowBackground(Color.clear)
                }
                ForEach(store.threads) { thread in
                    Button {
                        Task { await store.openThread(thread) }
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(thread.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(2)
                                Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if thread.id == store.currentThreadId {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.surface)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await store.deleteThread(thread) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .animation(Theme.springy, value: store.threads)
            .refreshable { await store.loadThreads() }
            .task { await store.loadThreads() }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .showsStoreErrors()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.newChat()
                        dismiss()
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @Environment(\.mood) private var mood

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                Text(formatted)
                    .font(.body)
                    .foregroundStyle(isUser ? Color.white : (message.isError ? Theme.danger : Theme.text))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(isUser ? mood.accent : Theme.surface, in: bubbleShape)
                    .textSelection(.enabled)
                ForEach(message.actions, id: \.self) { action in
                    ActionChip(action: action)
                }
            }
            if !isUser { Spacer(minLength: 48) }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 22,
                               bottomLeadingRadius: isUser ? 22 : 6,
                               bottomTrailingRadius: isUser ? 6 : 22,
                               topTrailingRadius: 22,
                               style: .continuous)
    }

    /// Assistant replies may use light markdown (bold, lists); keep line breaks.
    private var formatted: AttributedString {
        if !isUser, let parsed = try? AttributedString(
            markdown: message.text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return parsed
        }
        return AttributedString(message.text)
    }
}

/// Something the assistant did, e.g. "Added “Soccer” on Sat 10:00".
struct ActionChip: View {
    let action: AssistantAction

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
            Text(action.summary)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.success.opacity(0.14), in: Capsule())
    }
}

struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.muted)
                        .frame(width: 8, height: 8)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 6 - Double(i) * 0.7)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.surface, in: Capsule())
        }
        .accessibilityLabel("Ohana is typing")
    }
}

/// Expanding ring around the stop button while listening.
struct PulseRing: View {
    @State private var animate = false

    var body: some View {
        Circle()
            .stroke(Theme.danger.opacity(0.5), lineWidth: 3)
            .scaleEffect(animate ? 1.5 : 1)
            .opacity(animate ? 0 : 1)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}
