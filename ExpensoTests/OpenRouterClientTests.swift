import Foundation
import Testing
@testable import Expenso

@Suite("OpenRouter — isolated mocked transport and privacy contract")
struct OpenRouterClientTests {
    private func completion(_ message: OpenRouterMessage, finish: String = "stop") throws -> Data {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": encoded, "finish_reason": finish]]])
    }

    @Test("GPT-5 requests retain medium reasoning while other models receive no reasoning override",
          arguments: ["openai/gpt-5", "openai/gpt-5-mini", "openai/gpt-4.1-mini", "google/gemini-2.5-flash-lite"])
    func reasoningEffortPayload(_ model: String) async throws {
        let expected = OpenRouterMessage(role: "assistant", content: "Hello")
        let fixture = RouterFixture(reply: .http(200, try completion(expected)))
        defer { fixture.dispose() }
        let response = try await fixture.client.complete(apiKey: "fixture", model: model,
            messages: [.init(role: "user", content: "Hello")], requireTools: false, allowTools: true)
        #expect(response == expected && fixture.requests.count == 1)
        let request = try #require(fixture.requests.first)
        let payload = try fixture.body(request)
        #expect(payload["model"] as? String == model && payload["tool_choice"] as? String == "auto")
        if model.hasPrefix("openai/gpt-5") {
            let reasoning = try #require(payload["reasoning"] as? [String: String])
            #expect(reasoning == ["effort": "medium"])
        } else { #expect(payload["reasoning"] == nil) }
    }

    @Test("Planning requests require only the two read-only tools and deny provider data collection")
    func planningRequest() async throws {
        let call = OpenRouterToolCall(id: "call-1", function: .init(name: "query_spending", arguments: "{}"))
        let expected = OpenRouterMessage(role: "assistant", tool_calls: [call])
        let fixture = RouterFixture(reply: .http(200, try completion(expected, finish: "tool_calls")))
        defer { fixture.dispose() }
        let response = try await fixture.client.complete(apiKey: "fixture-key", model: OpenRouterClient.defaultModelID,
            messages: [.init(role: "user", content: "What did I spend this month?")], requireTools: true)
        #expect(response == expected)
        let request = try #require(fixture.requests.first)
        #expect(fixture.requests.count == 1)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        let authenticated = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key"
        #expect(authenticated) // Never render the header/key in assertion diagnostics.
        let payload = try fixture.body(request)
        #expect(payload["tool_choice"] as? String == "required")
        #expect(payload["max_tokens"] as? Int == 800)
        let provider = try #require(payload["provider"] as? [String: Any])
        #expect(provider["data_collection"] as? String == "deny")
        #expect(provider["require_parameters"] as? Bool == true)
        #expect(provider["allow_fallbacks"] == nil)
        let tools = try #require(payload["tools"] as? [[String: Any]])
        let functions = tools.compactMap { $0["function"] as? [String: Any] }
        #expect(functions.compactMap { $0["name"] as? String } == ["query_spending", "clarify_spending_question"])
        let parameters = try #require(functions.first?["parameters"] as? [String: Any])
        #expect(parameters["additionalProperties"] as? Bool == false)
        #expect(parameters["required"] as? [String] == ["period", "startDate", "endDate", "kind", "category", "search"])
        let properties = try #require(parameters["properties"] as? [String: [String: Any]])
        #expect(properties["period"]?["enum"] as? [String] == ["thisMonth", "lastMonth", "thisWeek", "last7Days", "last30Days", "yearToDate", "allTime", "custom"])
        #expect(properties["kind"]?["enum"] as? [String] == ["expense", "income", "all"])
    }

    @Test("Automatic chat allows a direct answer or read-only exploration tools", arguments: [
        "answer", "query_spending", "clarify_spending_question", "list_spending_transactions",
        "query_selected_transactions", "get_spending_catalogue"
    ])
    func automaticChat(_ action: String) async throws {
        let expected: OpenRouterMessage
        if action == "answer" { expected = .init(role: "assistant", content: "Which period should I inspect?") }
        else { expected = .init(role: "assistant", tool_calls: [.init(id: "inspect-1",
            function: .init(name: action, arguments: "{}"))]) }
        let fixture = RouterFixture(reply: .http(200, try completion(expected,
            finish: action == "answer" ? "stop" : "tool_calls")))
        defer { fixture.dispose() }
        let answer = try await fixture.client.complete(apiKey: "fixture", model: "example/model",
            messages: [.init(role: "user", content: "Help me understand my spending")],
            requireTools: false, allowTools: true)
        #expect(answer == expected)
        let payload = try fixture.body(#require(fixture.requests.first))
        #expect(payload["tool_choice"] as? String == "auto")
        let tools = try #require(payload["tools"] as? [[String: Any]])
        let functions = tools.compactMap { $0["function"] as? [String: Any] }
        #expect(functions.compactMap { $0["name"] as? String } == ["query_spending", "clarify_spending_question",
            "list_spending_transactions", "query_selected_transactions", "get_spending_catalogue"])
        let list = try #require(functions.first(where: { $0["name"] as? String == "list_spending_transactions" })?["parameters"] as? [String: Any])
        let listProperties = try #require(list["properties"] as? [String: [String: Any]])
        #expect(listProperties["limit"]?["maximum"] as? Int == SpendingInvestigationLimits.pageSize)
        #expect(listProperties["limit"]?["minimum"] as? Int == 1)
        #expect(listProperties["offset"]?["minimum"] as? Int == 0)
        #expect(listProperties["spendingType"] == nil)
        #expect(listProperties["category"] == nil)
        #expect(listProperties["search"] == nil)
        let aggregate = try #require(functions.first(where: { $0["name"] as? String == "query_spending" })?["parameters"] as? [String: Any])
        #expect(aggregate["required"] as? [String] == ["period", "startDate", "endDate", "kind"])
        let aggregateProperties = try #require(aggregate["properties"] as? [String: Any])
        #expect(aggregateProperties["category"] == nil && aggregateProperties["spendingType"] == nil)
        let selected = try #require(functions.first(where: { $0["name"] as? String == "query_selected_transactions" })?["parameters"] as? [String: Any])
        let selectedProperties = try #require(selected["properties"] as? [String: [String: Any]])
        #expect(selectedProperties["ids"]?["maxItems"] as? Int == SpendingInvestigationLimits.selectedTransactions)
        #expect(selectedProperties["ids"]?["uniqueItems"] as? Bool == true)
        let catalogue = try #require(functions.first(where: { $0["name"] as? String == "get_spending_catalogue" })?["parameters"] as? [String: Any])
        #expect((catalogue["properties"] as? [String: Any])?.isEmpty == true)
        #expect((catalogue["required"] as? [String])?.isEmpty == true)
        #expect((payload["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
    }

    @Test("Automatic chat rejects unsupported tool batches and inconsistent finish reasons", arguments: [
        "unknown", "duplicate", "too-many", "empty-tools", "stop-with-tools", "empty-answer"
    ])
    func invalidAutomaticChat(_ scenario: String) async throws {
        let call = OpenRouterToolCall(id: "inspect-1", function: .init(name: "get_spending_catalogue", arguments: "{}"))
        let calls: [OpenRouterToolCall]
        switch scenario {
        case "unknown": calls = [.init(id: "inspect-1", function: .init(name: "delete_transaction", arguments: "{}"))]
        case "duplicate": calls = [call, call]
        case "too-many": calls = (0..<4).map { .init(id: "inspect-\($0)", function: call.function) }
        case "empty-tools", "empty-answer": calls = []
        default: calls = [call]
        }
        let message = OpenRouterMessage(role: "assistant", content: " ", tool_calls: calls)
        let finish = ["stop-with-tools", "empty-answer"].contains(scenario) ? "stop" : "tool_calls"
        let fixture = RouterFixture(reply: .http(200, try completion(message, finish: finish)))
        defer { fixture.dispose() }
        await #expect(throws: OpenRouterError.malformed) {
            try await fixture.client.complete(apiKey: "fixture", model: "example/model",
                messages: [.init(role: "user", content: "Question")], requireTools: false, allowTools: true)
        }
        #expect(fixture.requests.count == 1)
    }

    @Test("Automatic chat preserves safe unfinished errors", arguments: ["length", "error", "private-provider-detail"])
    func automaticChatUnfinished(_ finish: String) async throws {
        let fixture = RouterFixture(reply: .http(200, try completion(.init(role: "assistant", content: "Partial"), finish: finish)))
        defer { fixture.dispose() }
        do {
            _ = try await fixture.client.complete(apiKey: "fixture", model: "example/model",
                messages: [.init(role: "user", content: "Question")], requireTools: false, allowTools: true)
            Issue.record("Expected unfinished response rejection")
        } catch {
            let expected: OpenRouterError = finish == "length" ? .outputLimit : .unfinished(finish == "error" ? "error" : "unknown")
            #expect(error as? OpenRouterError == expected)
            #expect(!error.localizedDescription.contains("private-provider-detail"))
        }
    }

    @Test("Automatic tools cannot mix with classification JSON or image extraction")
    func automaticChatJSONConflict() async {
        let fixture = RouterFixture(reply: .http(200, Data()))
        defer { fixture.dispose() }
        await #expect(throws: OpenRouterError.malformed) {
            try await fixture.client.complete(apiKey: "fixture", model: "example/model",
                messages: [.init(role: "user", content: "Question")], requireTools: false, allowTools: true, jsonOnly: true)
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test("Legacy required planning does not accept exploration tools")
    func legacyPlanningToolsUnchanged() async throws {
        let call = OpenRouterToolCall(id: "catalogue", function: .init(name: "get_spending_catalogue", arguments: "{}"))
        let fixture = RouterFixture(reply: .http(200, try completion(.init(role: "assistant", tool_calls: [call]), finish: "tool_calls")))
        defer { fixture.dispose() }
        await #expect(throws: OpenRouterError.malformed) {
            try await fixture.client.complete(apiKey: "fixture", model: "example/model",
                messages: [.init(role: "user", content: "Question")], requireTools: true)
        }
    }

    @Test("Image requests use bounded data URLs and keep privacy routing without tools")
    func imageRequest() async throws {
        let fixture = RouterFixture(reply: .http(200, try completion(.init(role: "assistant", content: "{\"transactions\":[]}"))))
        defer { fixture.dispose() }
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        _ = try await fixture.client.complete(apiKey: "fixture-key", model: "google/gemini-2.5-flash",
            messages: [.init(role: "system", content: "Extract"), .init(role: "user", content: "This image")],
            requireTools: false, jsonOnly: true, outputTokenLimit: 4_000, imageData: bytes)
        let payload = try fixture.body(#require(fixture.requests.first))
        let messages = try #require(payload["messages"] as? [[String: Any]])
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect((parts[1]["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64," + bytes.base64EncodedString())
        #expect(payload["max_tokens"] as? Int == 4_000 && payload["tools"] == nil)
        #expect((payload["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
    }

    @Test("Invalid or oversized images never reach transport")
    func imageBounds() async throws {
        let fixture = RouterFixture(reply: .http(200, try completion(.init(role: "assistant", content: "{}"))))
        defer { fixture.dispose() }
        for bytes in [Data([1, 2, 3]), Data([0xff, 0xd8, 0xff]) + Data(repeating: 0, count: 3 * 1_024 * 1_024)] {
            do {
                _ = try await fixture.client.complete(apiKey: "fixture", model: "example/model",
                    messages: [.init(role: "system", content: "Extract"), .init(role: "user", content: "Image")],
                    requireTools: false, jsonOnly: true, imageData: bytes)
                Issue.record("Expected bounded rejection")
            } catch { #expect(error as? OpenRouterError == .malformed) }
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test("Classification requests enforce JSON and privacy routing without chat tools")
    func classificationRequest() async throws {
        let fixture = RouterFixture(reply: .http(200, try completion(.init(role: "assistant", content: "{\"items\":[]}"))))
        defer { fixture.dispose() }
        _ = try await fixture.client.complete(apiKey: "fixture-key", model: "example/model",
            messages: [.init(role: "user", content: "[]")], requireTools: false, jsonOnly: true, outputTokenLimit: 2_000)
        let payload = try fixture.body(#require(fixture.requests.first))
        #expect(payload["max_tokens"] as? Int == 2_000)
        #expect((payload["response_format"] as? [String: String])?["type"] == "json_object")
        #expect(payload["tools"] == nil && payload["tool_choice"] == nil)
        #expect((payload["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
    }

    @Test("Final requests carry tool evidence but expose no tools to the model")
    func finalRequest() async throws {
        let fixture = RouterFixture(reply: .http(200, try completion(.init(role: "assistant", content: "Total: 100 RUB."))))
        defer { fixture.dispose() }
        let call = OpenRouterToolCall(id: "query-1", function: .init(name: "query_spending", arguments: "{}"))
        let messages: [OpenRouterMessage] = [.init(role: "assistant", tool_calls: [call]),
            .init(role: "tool", content: "{\"totalExpense\":\"100\"}", tool_call_id: "query-1")]
        let response = try await fixture.client.complete(apiKey: "fixture-key", model: "example/model", messages: messages, requireTools: false)
        #expect(response.content == "Total: 100 RUB.")
        let payload = try fixture.body(#require(fixture.requests.first))
        #expect(payload["tools"] == nil && payload["tool_choice"] == nil)
        let encodedMessages = try JSONSerialization.data(withJSONObject: #require(payload["messages"]))
        #expect(try JSONDecoder().decode([OpenRouterMessage].self, from: encodedMessages) == messages)
    }

    @Test("HTTP errors are fixed safe messages, without retries or raw API details", arguments: [
        (401, OpenRouterError.authentication), (403, .authentication), (402, .credits),
        (429, .rateLimited), (503, .unavailable)
    ])
    func safeErrors(_ status: Int, expected: OpenRouterError) async {
        let fixture = RouterFixture(reply: .http(status, Data("private provider diagnostic".utf8)))
        defer { fixture.dispose() }
        do {
            _ = try await fixture.client.complete(apiKey: "fixture-key", model: "example/model",
                messages: [.init(role: "user", content: "Question")], requireTools: false)
            Issue.record("Expected a sanitized transport error")
        } catch {
            #expect(error as? OpenRouterError == expected)
            #expect(!error.localizedDescription.contains("private provider diagnostic"))
        }
        #expect(fixture.requests.count == 1)
    }

    @Test("Network errors are sanitized and URLSession cancellation propagates", arguments: [
        URLError.Code.notConnectedToInternet, .cancelled
    ])
    func transportErrors(_ code: URLError.Code) async {
        let fixture = RouterFixture(reply: .failure(code))
        defer { fixture.dispose() }
        do {
            _ = try await fixture.client.complete(apiKey: "fixture-key", model: "example/model",
                messages: [.init(role: "user", content: "Question")], requireTools: false)
            Issue.record("Expected transport failure")
        } catch {
            if code == .cancelled { #expect(error is CancellationError) }
            else { #expect(error as? OpenRouterError == .network) }
        }
    }

    @Test("Malformed, oversized and unfinished final responses are rejected", arguments: [
        "malformed", "oversized", "length", "content_filter", "tool_calls", "empty"
    ])
    func rejectedFinal(_ scenario: String) async throws {
        let data: Data
        if scenario == "malformed" { data = Data("not-json".utf8) }
        else if scenario == "oversized" { data = Data(repeating: 0x20, count: 1_048_577) }
        else { data = try completion(.init(role: "assistant", content: scenario == "empty" ? " " : "Partial"),
            finish: scenario == "empty" ? "stop" : scenario) }
        let fixture = RouterFixture(reply: .http(200, data))
        defer { fixture.dispose() }
        await #expect(throws: OpenRouterError.self) {
            try await fixture.client.complete(apiKey: "fixture-key", model: "example/model",
                messages: [.init(role: "user", content: "Question")], requireTools: false)
        }
    }

    @Test("Only length-limited responses are eligible for bounded classification recovery", arguments: ["length", "content_filter", "error", "private-provider-message", "missing"])
    func finishReasonPreserved(_ finish: String) async throws {
        var data = try completion(.init(role: "assistant", content: "Partial"), finish: finish)
        if finish == "missing" {
            var payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var choices = try #require(payload["choices"] as? [[String: Any]])
            choices[0].removeValue(forKey: "finish_reason")
            payload["choices"] = choices
            data = try JSONSerialization.data(withJSONObject: payload)
        }
        let fixture = RouterFixture(reply: .http(200, data))
        defer { fixture.dispose() }
        do {
            _ = try await fixture.client.complete(apiKey: "fixture", model: "example/model",
                messages: [.init(role: "user", content: "[]")], requireTools: false, jsonOnly: true)
            Issue.record("Unfinished output must be rejected")
        } catch {
            let reason = finish == "private-provider-message" ? "unknown" : finish
            #expect(error as? OpenRouterError == (finish == "length" ? .outputLimit : .unfinished(reason)))
            #expect(!error.localizedDescription.contains("private-provider-message"))
        }
        #expect(fixture.requests.count == 1)
    }

    @Test("Unknown tool names and missing mandatory tool calls are rejected", arguments: [false, true])
    func invalidTools(_ missingCalls: Bool) async throws {
        let call = OpenRouterToolCall(id: "call-1", function: .init(name: "delete_everything", arguments: "{}"))
        let fixture = RouterFixture(reply: .http(200, try completion(.init(role: "assistant", tool_calls: missingCalls ? [] : [call]), finish: "tool_calls")))
        defer { fixture.dispose() }
        await #expect(throws: OpenRouterError.self) {
            try await fixture.client.complete(apiKey: "fixture-key", model: "example/model",
                messages: [.init(role: "user", content: "Question")], requireTools: true)
        }
    }

    @Test("Model listing is unauthenticated and requires both tool parameters")
    func modelCatalog() async throws {
        let payload = Data(#"{"data":[{"id":"plain","name":"Plain","pricing":{"prompt":"0","completion":"0"},"supported_parameters":["tools"]},{"id":"good","name":"Good","pricing":{"prompt":"0.0000001","completion":"0.0000004"},"supported_parameters":["tools","tool_choice"]},{"id":"none","name":"None","pricing":{"prompt":"0","completion":"0"}}]}"#.utf8)
        let fixture = RouterFixture(reply: .http(200, payload))
        defer { fixture.dispose() }
        let models = try await fixture.client.models()
        #expect(models.map(\.id) == ["good"])
        #expect(models.first?.priceLabel == "Input $0.1 · Output $0.4 / 1M tokens (USD)")
        let request = try #require(fixture.requests.first)
        #expect(request.url?.path == "/api/v1/models" && request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
    }

    @Test("Invalid authentication and pre-entry cancellation perform no HTTP")
    func beforeTransport() async {
        let fixture = RouterFixture(reply: .http(200, Data()))
        defer { fixture.dispose() }
        await #expect(throws: OpenRouterError.authentication) {
            try await fixture.client.complete(apiKey: " ", model: "example/model",
                messages: [.init(role: "user", content: "Question")], requireTools: false)
        }
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.client.complete(apiKey: "fixture-key", model: "example/model",
                messages: [.init(role: "user", content: "Question")], requireTools: false)
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(fixture.requests.isEmpty)
    }

    @Test("Exploration accepts expanded context and still rejects oversized requests")
    func explorationRequestBudget() async throws {
        let expected = OpenRouterMessage(role: "assistant", content: "Finished")
        let fixture = RouterFixture(reply: .http(200, try completion(expected)))
        defer { fixture.dispose() }
        let result = try await fixture.client.complete(apiKey: "fixture-key", model: "example/model",
            messages: [.init(role: "user", content: String(repeating: "x", count: 200_000))],
            requireTools: false, allowTools: true, outputTokenLimit: SpendingInvestigationLimits.responseTokens)
        #expect(result == expected && fixture.requests.count == 1)
        let payload = try fixture.body(#require(fixture.requests.first))
        #expect(payload["max_tokens"] as? Int == SpendingInvestigationLimits.responseTokens)
        await #expect(throws: OpenRouterError.malformed) {
            try await fixture.client.complete(apiKey: "fixture-key", model: "example/model",
                messages: [.init(role: "user", content: "Hello")], requireTools: true,
                outputTokenLimit: SpendingInvestigationLimits.responseTokens)
        }
        await #expect(throws: OpenRouterError.malformed) {
            try await fixture.client.complete(apiKey: "fixture-key", model: "example/model",
                messages: [.init(role: "user", content: String(repeating: "x", count: SpendingInvestigationLimits.requestBytes))],
                requireTools: false, allowTools: true)
        }
        #expect(fixture.requests.count == 1)
    }

    @Test("Mandatory planning keeps its request bound even when allowTools is also set", arguments: [false, true])
    func oversizedRequest(_ allowTools: Bool) async {
        let fixture = RouterFixture(reply: .http(200, Data()))
        defer { fixture.dispose() }
        await #expect(throws: OpenRouterError.malformed) {
            try await fixture.client.complete(apiKey: "fixture-key", model: "example/model",
                messages: [.init(role: "user", content: String(repeating: "x", count: 131_072))], requireTools: true, allowTools: allowTools)
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test("More than three tool calls are refused")
    func toolCallLimit() async throws {
        let calls = (0..<4).map { OpenRouterToolCall(id: "call-\($0)", function: .init(name: "query_spending", arguments: "{}")) }
        let fixture = RouterFixture(reply: .http(200, try completion(.init(role: "assistant", tool_calls: calls), finish: "tool_calls")))
        defer { fixture.dispose() }
        await #expect(throws: OpenRouterError.malformed) {
            try await fixture.client.complete(apiKey: "fixture-key", model: "example/model",
                messages: [.init(role: "user", content: "Question")], requireTools: true)
        }
    }

    @Test("The default redirect policy refuses same-host and external destinations", arguments: [
        "https://openrouter.ai/other", "https://other.example/receive"
    ])
    func redirectPolicy(_ destination: String) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        let response = try #require(HTTPURLResponse(url: origin, statusCode: 307, httpVersion: nil, headerFields: nil))
        let task = session.dataTask(with: origin)
        let redirected: URLRequest? = await withCheckedContinuation { continuation in
            OpenRouterRedirectBlocker().urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: destination)!)) { continuation.resume(returning: $0) }
        }
        #expect(redirected == nil)
    }
}

/// Test-only unchecked Sendable: all registry, response and request state is locked.
private final class RouterFixture: @unchecked Sendable {
    enum Reply { case http(Int, Data), failure(URLError.Code) }
    let id: String
    private let lock = NSLock()
    private let reply: Reply
    private var recorded: [URLRequest] = []
    private var session: URLSession!
    let client: OpenRouterClient
    init(reply: Reply) {
        let id = UUID().uuidString
        self.id = id
        self.reply = reply
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouterURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Expenso-Test-ID": id]
        let session = URLSession(configuration: configuration)
        self.session = session
        client = OpenRouterClient(session: session)
        RouterURLProtocol.registry.insert(self)
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func respond(to request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }; recorded.append(request); return reply
    }
    func dispose() { session.invalidateAndCancel(); RouterURLProtocol.registry.remove(id) }
    func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var buffer = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                buffer.append(contentsOf: bytes.prefix(count))
            }
            data = buffer
        } else { throw OpenRouterError.malformed }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class RouterRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: RouterFixture] = [:]
    func insert(_ fixture: RouterFixture) { lock.lock(); defer { lock.unlock() }; fixtures[fixture.id] = fixture }
    func remove(_ id: String) { lock.lock(); defer { lock.unlock() }; fixtures[id] = nil }
    func get(_ id: String) -> RouterFixture? { lock.lock(); defer { lock.unlock() }; return fixtures[id] }
}

private final class RouterURLProtocol: URLProtocol {
    static let registry = RouterRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Expenso-Test-ID"), let fixture = Self.registry.get(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        switch fixture.respond(to: request) {
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
