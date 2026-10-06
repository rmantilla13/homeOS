import Foundation
import Supabase

/// One server-sent event from the `assistant` function (PLATFORM_SPEC §2.1).
enum AssistantEvent: Equatable {
    case thread(UUID)
    case delta(String)
    case action(AssistantAction)
    case done(AssistantReply)
    case error(String)

    /// `done` and `error` end the stream.
    var isFinal: Bool {
        switch self {
        case .done, .error: return true
        default: return false
        }
    }
}

/// A failure worth showing as-is: in a chat bubble, or spoken by Siri.
struct AssistantError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    static let unreachable = AssistantError(message: "I couldn't reach Ohana just now. Check your connection and try again.")
    static let signedOut = AssistantError(message: "Sign in to Ohana on your iPhone first.")
}

/// Calls the `assistant` edge function over URLSession rather than
/// `supabase.functions`, so replies can stream token by token.
struct AssistantClient {
    enum Mode: String { case chat, quick }

    private struct Body: Encodable {
        var message: String
        var threadId: String?
        var familyId: String?
        var mode: String
        var stream: Bool

        enum CodingKeys: String, CodingKey {
            case message, mode, stream
            case threadId = "thread_id"
            case familyId = "family_id"
        }
    }

    private struct ErrorBody: Decodable { var error: String? }

    var url = Config.supabaseURL.appendingPathComponent("functions/v1/assistant")

    /// Streams a reply, calling `onEvent` on the main actor for each event.
    /// Ends after `done` or `error`; throws only if the request itself fails.
    func stream(_ message: String, threadId: UUID?, familyId: UUID?,
                onEvent: @MainActor (AssistantEvent) -> Void) async throws {
        let request = try await makeRequest(message, threadId: threadId, familyId: familyId, mode: .chat, streaming: true)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 16_384 { break }
            }
            throw Self.failure(status: status, body: body)
        }

        // Split lines by hand: `bytes.lines` drops the blank lines that end SSE events.
        var parser = SSEParser()
        var line: [UInt8] = []
        for try await byte in bytes {
            guard byte == UInt8(ascii: "\n") else {
                line.append(byte)
                continue
            }
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            if let event = parser.feed(line: text).flatMap(Self.decode) {
                await onEvent(event)
                if event.isFinal { return }
            }
        }
        // The stream closed without a trailing blank line. A complete last event
        // still counts; a `done` cut off mid-way can't be read, so it's dropped
        // and the text that already streamed stays instead of becoming an error.
        if !line.isEmpty { _ = parser.feed(line: String(decoding: line, as: UTF8.self)) }
        if let raw = parser.finish(), let event = Self.decode(raw) {
            if case .error = event, raw.name == "done" { return }
            await onEvent(event)
        }
    }

    /// A short spoken-style answer in a new thread (Siri). No streaming.
    func quickAnswer(_ question: String) async throws -> AssistantReply {
        let request = try await makeRequest(question, threadId: nil, familyId: nil, mode: .quick, streaming: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status: status, body: data) }
        return try JSONDecoder().decode(AssistantReply.self, from: data)
    }

    private func makeRequest(_ message: String, threadId: UUID?, familyId: UUID?,
                             mode: Mode, streaming: Bool) async throws -> URLRequest {
        let token: String
        do {
            token = try await supabase.auth.session.accessToken  // refreshed if it expired
        } catch {
            throw supabase.auth.currentSession == nil ? AssistantError.signedOut : AssistantError.unreachable
        }
        var request = URLRequest(url: url, timeoutInterval: streaming ? 120 : 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        // UUIDs go lowercase: the function compares them as strings.
        request.httpBody = try JSONEncoder().encode(Body(
            message: message,
            threadId: threadId?.uuidString.lowercased(),
            familyId: familyId?.uuidString.lowercased(),
            mode: mode.rawValue,
            stream: streaming))
        return request
    }

    private static func failure(status: Int, body: Data) -> AssistantError {
        let serverMessage = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
        switch status {
        case 401:
            return AssistantError(message: "Your session ended. Sign in to Ohana again.")
        case 403:
            return AssistantError(message: (serverMessage ?? "Ohana can't answer for this account right now.").sentenceCased)
        case 400..<500:
            return AssistantError(message: (serverMessage ?? "Ohana didn't understand that request.").sentenceCased)
        case 500...:
            return AssistantError(message: serverMessage.map { $0.sentenceCased } ?? "Ohana is having trouble right now. Try again in a moment.")
        default:
            return .unreachable
        }
    }

    private struct ThreadPayload: Decodable { var thread_id: UUID }
    private struct DeltaPayload: Decodable { var text: String }
    private struct ErrorPayload: Decodable { var message: String? }

    /// Maps a raw SSE event onto the spec's events; unknown names are skipped.
    static func decode(_ raw: SSEParser.Event) -> AssistantEvent? {
        let data = Data(raw.data.utf8)
        let decoder = JSONDecoder()
        switch raw.name {
        case "thread":
            return (try? decoder.decode(ThreadPayload.self, from: data)).map { AssistantEvent.thread($0.thread_id) }
        case "delta":
            return (try? decoder.decode(DeltaPayload.self, from: data)).map { AssistantEvent.delta($0.text) }
        case "action":
            return (try? decoder.decode(AssistantAction.self, from: data)).map { AssistantEvent.action($0) }
        case "done":
            guard let reply = try? decoder.decode(AssistantReply.self, from: data) else {
                return .error("Ohana sent a reply I couldn't read.")
            }
            return .done(reply)
        case "error":
            let message = (try? decoder.decode(ErrorPayload.self, from: data))?.message
            return .error(message ?? "Something went wrong. Try again.")
        default:
            return nil
        }
    }
}

/// Incremental parser for `text/event-stream`: feed it lines without their
/// line endings; a blank line completes an event.
struct SSEParser {
    struct Event: Equatable {
        var name: String
        var data: String
    }

    private var name = ""
    private var dataLines: [String] = []

    mutating func feed(line: String) -> Event? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }  // comment / keep-alive
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": dataLines.append(String(value))
        default: break  // id, retry
        }
        return nil
    }

    /// Flushes an event the stream ended without a blank line after.
    mutating func finish() -> Event? { dispatch() }

    private mutating func dispatch() -> Event? {
        defer {
            name = ""
            dataLines = []
        }
        guard !dataLines.isEmpty else { return nil }
        return Event(name: name.isEmpty ? "message" : name, data: dataLines.joined(separator: "\n"))
    }
}
