import Foundation
import Testing
@testable import Expenso

/// Prepared regression source in the ExpensoTests target; it performs no live HTTP.
struct ExchangeRateServiceTests {
    @Test("API common-reference BAM to RUB ratio is exact")
    func apiRatio() throws {
        let snapshot = CurrencyRateSnapshot(date: "2026-10-03",
            rates: ["USD": 1, "BAM": 2, "RUB": 100], source: "fixture")
        #expect(try snapshot.rate(from: "BAM", to: "RUB") == 50)
        #expect(try snapshot.rate(from: "rub", to: "bam") == Decimal(string: "0.02"))
        #expect(try snapshot.rate(from: "BAM", to: "BAM") == 1)
    }

    @Test("Manual original-currency anchor needs no fabricated USD rate")
    func manualAnchor() throws {
        let snapshot = CurrencyRateSnapshot(date: "2026-10-03",
            rates: ["BAM": 1, "RUB": 50], source: "Manual — anchored to BAM")
        #expect(try snapshot.rate(from: "BAM", to: "RUB") == 50)
        #expect(try snapshot.rate(from: "RUB", to: "BAM") == Decimal(string: "0.02"))
        #expect(throws: ExchangeRateError.self) { try snapshot.rate(from: "USD", to: "RUB") }
    }

    @Test("Missing, unsupported, zero, negative, and NaN rates fail")
    func invalidRatios() {
        let invalidTables: [[String: Decimal]] = [
            ["BAM": 1], ["BAM": 1, "RUB": 0],
            ["BAM": 0, "RUB": 1], ["BAM": 1, "RUB": -1],
            ["BAM": 1, "RUB": .nan], ["BAM": .nan, "RUB": 1]
        ]
        for rates in invalidTables {
            let snapshot = CurrencyRateSnapshot(date: "2026-10-03", rates: rates, source: "fixture")
            #expect(throws: ExchangeRateError.self) { try snapshot.rate(from: "BAM", to: "RUB") }
        }
        let crypto = CurrencyRateSnapshot(date: "2026-10-03", rates: ["BTC": 1, "RUB": 50], source: "fixture")
        #expect(throws: ExchangeRateError.self) { try crypto.rate(from: "BTC", to: "RUB") }
    }

    @Test("A new actor reuses the persistent cache within 24 hours")
    func persistentCache() async throws {
        let fixture = RateFixture(replies: [.http(200, Self.payload())])
        defer { fixture.dispose() }
        let first = try await fixture.service().snapshot(for: "2026-10-03")
        fixture.clock.advance(by: 23 * 60 * 60)
        let second = try await fixture.service().snapshot(for: "2026-10-03")
        #expect(second == first)
        #expect(fixture.requests.count == 1)
        #expect(FileManager.default.fileExists(atPath:
            fixture.directory.appendingPathComponent("2026-10-03.json").path))
    }

    @Test("At exactly 24 hours the in-memory and disk caches expire")
    func exactExpiry() async throws {
        let fixture = RateFixture(replies: [.http(200, Self.payload()), .http(200, Self.payload(rub: 120))])
        defer { fixture.dispose() }
        let service = fixture.service()
        _ = try await service.snapshot(for: "2026-10-03")
        fixture.clock.advance(by: 24 * 60 * 60)
        let refreshed = try await service.snapshot(for: "2026-10-03")
        #expect(try refreshed.rate(from: "BAM", to: "RUB") == 60)
        #expect(fixture.requests.count == 2)
    }

    @Test("Expired persistent rates are not served when both hosts are offline")
    func staleOffline() async throws {
        let fixture = RateFixture(replies: [.http(200, Self.payload()),
            .failure(.notConnectedToInternet), .failure(.notConnectedToInternet)])
        defer { fixture.dispose() }
        _ = try await fixture.service().snapshot(for: "2026-10-03")
        fixture.clock.advance(by: 24 * 60 * 60)
        await #expect(throws: ExchangeRateError.self) {
            try await fixture.service().snapshot(for: "2026-10-03")
        }
        #expect(fixture.requests.count == 3)
    }

    @Test("Primary HTTP failure uses the mirror for exactly the requested day")
    func sameDayMirror() async throws {
        let fixture = RateFixture(replies: [.http(503, ""), .http(200, Self.payload())])
        defer { fixture.dispose() }
        let snapshot = try await fixture.service().snapshot(for: "2026-10-03")
        let requests = fixture.requests
        try #require(requests.count == 2)
        #expect(requests[0].url?.absoluteString == "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@2026-10-03/v1/currencies/usd.min.json")
        #expect(requests[1].url?.absoluteString == "https://2026-10-03.currency-api.pages.dev/v1/currencies/usd.min.json")
        #expect(snapshot.source == requests[1].url?.absoluteString)
        #expect(snapshot.date == "2026-10-03")
        for request in requests {
            #expect(request.httpBody == nil)
            #expect(request.httpMethod == "GET")
            #expect(request.timeoutInterval == 20)
        }
    }

    @Test("Wrong-day payloads from both hosts are rejected")
    func wrongDay() async {
        let fixture = RateFixture(replies: [.http(200, Self.payload(date: "2026-10-02")),
            .http(200, Self.payload(date: "2026-10-04"))])
        defer { fixture.dispose() }
        await #expect(throws: ExchangeRateError.self) {
            try await fixture.service().snapshot(for: "2026-10-03")
        }
        #expect(fixture.requests.count == 2)
        #expect(!FileManager.default.fileExists(atPath:
            fixture.directory.appendingPathComponent("2026-10-03.json").path))
    }

    @Test("Invalid and future dates fail before any HTTP",
          arguments: ["", "2026-2-01", "2026-02-30", "2026-13-01", "2026-10-05", "../2026-10-03"])
    func invalidDate(_ date: String) async {
        let fixture = RateFixture(replies: [])
        defer { fixture.dispose() }
        await #expect(throws: ExchangeRateError.self) {
            try await fixture.service().snapshot(for: date)
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test("Payload retains positive ISO fiat only, including BAM and RUB")
    func filtersRates() async throws {
        let body = """
        {"date":"2026-10-03","usd":{"usd":1,"bam":2,"rub":100,"eur":0,"gbp":-1,"btc":0.001,"notacurrency":5}}
        """
        let fixture = RateFixture(replies: [.http(200, body)])
        defer { fixture.dispose() }
        let snapshot = try await fixture.service().snapshot(for: "2026-10-03")
        #expect(snapshot.rates == ["USD": 1, "BAM": 2, "RUB": 100])
        #expect(throws: ExchangeRateError.self) { try snapshot.rate(from: "EUR", to: "RUB") }
    }

    @Test("Provider tables require the USD reference rate to equal one")
    func rejectsInvalidReference() async {
        let body = "{\"date\":\"2026-10-03\",\"usd\":{\"usd\":2,\"bam\":2,\"rub\":100}}"
        let fixture = RateFixture(replies: [.http(200, body), .http(200, body)])
        defer { fixture.dispose() }
        await #expect(throws: ExchangeRateError.self) {
            try await fixture.service().snapshot(for: "2026-10-03")
        }
        #expect(fixture.requests.count == 2)
    }

    @Test("An already-cancelled caller fails before HTTP")
    func cancelledBeforeEntry() async {
        let fixture = RateFixture(replies: [])
        defer { fixture.dispose() }
        let service = fixture.service()
        let gate = RateEntryGate()
        let caller = Task {
            await gate.wait()
            return try await service.snapshot(for: "2026-10-03")
        }
        caller.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(fixture.requests.isEmpty)
    }

    private static func payload(date: String = "2026-10-03", rub: Int = 100) -> String {
        "{\"date\":\"\(date)\",\"usd\":{\"usd\":1,\"bam\":2,\"rub\":\(rub)}}"
    }
}

/// Cancellation is set before entry regardless of task scheduling. No sleeps.
private actor RateEntryGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

/// The unchecked conformance is confined to test doubles: all mutable state is
/// protected by NSLock; callbacks and URLSession access happen outside locks.
private final class RateFixture: @unchecked Sendable {
    enum Reply {
        case http(Int, String)
        case failure(URLError.Code)
    }

    let id = UUID().uuidString
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExpensoRatesTests-\(UUID().uuidString)", isDirectory: true)
    let clock = RateClock()
    private let lock = NSLock()
    private var replies: [Reply]
    private var recordedRequests: [URLRequest] = []
    private var sessions: [URLSession] = []

    init(replies: [Reply]) {
        self.replies = replies
        RateURLProtocol.registry.register(self)
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func service() -> ExchangeRateService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateURLProtocol.self]
        configuration.httpAdditionalHeaders = [RateURLProtocol.header: id]
        let session = URLSession(configuration: configuration)
        lock.lock()
        sessions.append(session)
        lock.unlock()
        return ExchangeRateService(session: session, storageURL: directory, now: { [clock] in clock.now })
    }

    func nextReply(for request: URLRequest) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        return replies.isEmpty ? .failure(.badServerResponse) : replies.removeFirst()
    }

    func dispose() {
        lock.lock()
        let sessions = sessions
        self.sessions.removeAll()
        lock.unlock()
        sessions.forEach { $0.invalidateAndCancel() }
        RateURLProtocol.registry.remove(id)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class RateClock: @unchecked Sendable {
    private let lock = NSLock()
    // Match the service's local-day validation without modifying global time zone.
    private var date = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date.addTimeInterval(interval)
    }
}

private final class RateRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: RateFixture] = [:]

    func register(_ fixture: RateFixture) {
        lock.lock()
        defer { lock.unlock() }
        fixtures[fixture.id] = fixture
    }

    func fixture(_ id: String) -> RateFixture? {
        lock.lock()
        defer { lock.unlock() }
        return fixtures[id]
    }

    func remove(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        fixtures[id] = nil
    }
}

private final class RateURLProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-Expenso-Test-Fixture"
    static let registry = RateRegistry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.header),
              let fixture = Self.registry.fixture(id), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch fixture.nextReply(for: request) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let body):
            guard let response = HTTPURLResponse(url: url, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { }
}
