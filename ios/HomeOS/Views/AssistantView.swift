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

/// Chat with the family assistant (the `assistant` edge function).
struct AssistantView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let launch: AssistantLaunch

    @State private var draft = ""
    @State private var dictation = Dictation()
    @State private var didLaunch = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if store.chat.isEmpty && !store.isThinking {
                            emptyState
                        }
                        ForEach(store.chat) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity))
                        }
                        if store.isThinking {
                            TypingIndicator()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("typing")
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .animation(Theme.springy, value: store.chat)
                    .animation(.easeInOut(duration: 0.2), value: store.isThinking)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.chat.count) { scrollToBottom(proxy) }
                .onChange(of: store.isThinking) { scrollToBottom(proxy) }
            }
            inputBar
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
        .task {
            guard !didLaunch else { return }
            didLaunch = true
            if let prompt = launch.prompt {
                await store.ask(prompt)
            } else if launch.listen {
                await dictation.start()
            } else {
                focused = true
            }
        }
        .onChange(of: dictation.transcript) { _, text in
            if !text.isEmpty { draft = text }
        }
        .onDisappear { dictation.cancel() }
        .alert("Voice", isPresented: Binding(
            get: { dictation.errorMessage != nil },
            set: { if !$0 { dictation.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictation.errorMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack {
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
                Text("homeOS").font(.headline).foregroundStyle(Theme.text)
                Text(store.isThinking ? "Thinking…" : "Family assistant")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button { withAnimation(Theme.springy) { store.resetChat() } } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40)
                    .background(Theme.surface, in: Circle())
            }
            .disabled(store.chat.isEmpty || store.isThinking)
            .accessibilityLabel("New conversation")
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
                    Button { Task { await store.ask(suggestion.prompt) } } label: {
                        Chip(title: suggestion.title, icon: suggestion.icon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .padding(.top, 70)
        .transition(.opacity)
    }

    private var firstName: String {
        store.me?.displayName.split(separator: " ").first.map(String.init) ?? "there"
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(dictation.isRecording ? "Listening…" : "Ask homeOS anything", text: $draft, axis: .vertical)
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
                        .disabled(store.isThinking)
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
        guard !text.isEmpty else { return }
        dictation.cancel()
        dictation.transcript = ""
        draft = ""
        Task { await store.ask(text) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if store.isThinking {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = store.chat.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
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
        .accessibilityLabel("homeOS is typing")
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
