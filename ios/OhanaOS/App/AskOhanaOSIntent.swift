import AppIntents

/// "Ask Ohana": a quick, spoken-style answer from the family assistant,
/// without opening the app. Uses `mode: quick` and no thread, so the server
/// starts a fresh one (it shows up in the app's chat history). It sends
/// nothing until the signed-in person has allowed the assistant in the app.
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
        } else if let userId = AIConsent.savedUserId {
            if AIConsent.isAllowed(for: userId) {
                do {
                    answer = try await AssistantClient().quickAnswer(text).reply
                } catch let error as AssistantError {
                    answer = error.message
                } catch {
                    answer = AssistantError.unreachable.message
                }
            } else {
                // Siri can't show the consent screen, so nothing is sent until the app has asked.
                answer = "Open Ohana Display and allow the assistant first."
            }
        } else {
            answer = AssistantError.signedOut.message
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
