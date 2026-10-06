import AppIntents

/// "Ask Ohana": a quick, spoken-style answer from the family assistant,
/// without opening the app. Uses `mode: quick` and no thread, so the server
/// starts a fresh one (it shows up in the app's chat history).
struct AskOhanaOSIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Ohana"
    static let description: IntentDescription? = IntentDescription("Ask your family assistant a quick question about the calendar, chores, meals or lists.")
    /// Family plans aren't for whoever picks up a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask Ohana?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Ohana \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer: String
        if text.isEmpty {
            answer = "What would you like to ask?"
        } else {
            do {
                answer = try await AssistantClient().quickAnswer(text).reply
            } catch let error as AssistantError {
                answer = error.message
            } catch {
                answer = AssistantError.unreachable.message
            }
        }
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Siri phrases. A String parameter can't appear in a phrase, so Siri asks
/// for the question after "Ask Ohana".
struct OhanaOSShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOhanaOSIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Ask my family assistant in \(.applicationName)",
            ],
            shortTitle: "Ask Ohana",
            systemImageName: "sparkles"
        )
    }
}
