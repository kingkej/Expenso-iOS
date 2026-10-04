import Foundation

/// Rates share one reference currency for exactly the declared calendar day.
/// API tables use USD; manual tables may anchor to the original currency instead.
struct CurrencyRateSnapshot: Codable, Sendable, Equatable {
    let date: String
    let rates: [String: Decimal]
    let source: String

    func rate(from: String, to: String) throws -> Decimal {
        let sourceCode = from.uppercased()
        let targetCode = to.uppercased()
        guard ExchangeRateValidation.fiatCodes.contains(sourceCode),
              ExchangeRateValidation.fiatCodes.contains(targetCode),
              let sourceRate = rates[sourceCode], let targetRate = rates[targetCode] else {
            throw ExchangeRateError.unsupportedCurrency
        }
        guard ExchangeRateValidation.isValid(sourceRate),
              ExchangeRateValidation.isValid(targetRate) else {
            throw ExchangeRateError.invalidResponse
        }
        var numerator = targetRate
        var denominator = sourceRate
        var result = Decimal()
        let status = NSDecimalDivide(&result, &numerator, &denominator, .plain)
        guard (status == .noError || status == .lossOfPrecision),
              ExchangeRateValidation.isValid(result) else {
            throw ExchangeRateError.invalidResponse
        }
        return result
    }
}

actor ExchangeRateService {
    static let shared = ExchangeRateService()

    private let session: URLSession
    private let storageURL: URL
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval = 24 * 60 * 60
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<CurrencyRateSnapshot, Error>] = [:]

    /// `storageURL` is a directory, allowing tests to use an isolated cache location.
    init(session: URLSession = .shared, storageURL: URL? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.storageURL = storageURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first.map { $0.appendingPathComponent("ExpensoExchangeRates", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ExpensoExchangeRates", isDirectory: true)
        self.now = now
    }

    func snapshot(for date: String) async throws -> CurrencyRateSnapshot {
        try Task.checkCancellation()
        try ExchangeRateValidation.validateDate(date, now: now())
        if let entry = cache[date], isFresh(entry, for: date) { return entry.snapshot }
        if let entry = readCache(for: date), isFresh(entry, for: date) {
            cache[date] = entry
            return entry.snapshot
        }
        if let task = inFlight[date] {
            let snapshot = try await task.value
            try Task.checkCancellation()
            return snapshot
        }

        // Shared ownership is deliberate: cancelling one caller must not cancel
        // a rate request another caller is awaiting. Only the creator clears it.
        let task = Task { try await self.fetchSnapshot(for: date) }
        inFlight[date] = task
        defer { inFlight[date] = nil }
        let snapshot = try await task.value
        let entry = CacheEntry(fetchedAt: now(), snapshot: snapshot)
        cache[date] = entry
        writeCache(entry, for: date)
        try Task.checkCancellation()
        return snapshot
    }

    private func fetchSnapshot(for date: String) async throws -> CurrencyRateSnapshot {
        let endpoints = [
            "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@\(date)/v1/currencies/usd.min.json",
            "https://\(date).currency-api.pages.dev/v1/currencies/usd.min.json"
        ]
        for endpoint in endpoints {
            try Task.checkCancellation()
            guard let url = URL(string: endpoint) else { throw ExchangeRateError.invalidDate }
            // Only the date and public USD rate table are requested. No ledger,
            // transaction amount, notes, or currency selection leaves the device.
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpMethod = "GET"
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      data.count <= 1_000_000 else { throw ExchangeRateError.invalidResponse }
                let payload = try JSONDecoder().decode(APIPayload.self, from: data)
                guard payload.date == date else { throw ExchangeRateError.wrongDate }
                var rates: [String: Decimal] = [:]
                for (code, value) in payload.usd {
                    let isoCode = code.uppercased()
                    if ExchangeRateValidation.fiatCodes.contains(isoCode), ExchangeRateValidation.isValid(value) {
                        rates[isoCode] = value
                    }
                }
                guard rates["USD"] == 1, rates.count > 1 else { throw ExchangeRateError.invalidResponse }
                return CurrencyRateSnapshot(date: date, rates: rates, source: endpoint)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                // Try the alternate host, always for the same date.
                continue
            }
        }
        throw ExchangeRateError.unavailable(date)
    }

    private func isFresh(_ entry: CacheEntry, for date: String) -> Bool {
        let age = now().timeIntervalSince(entry.fetchedAt)
        guard age >= 0, age < lifetime, entry.snapshot.date == date,
              entry.snapshot.rates["USD"] == 1, entry.snapshot.rates.count > 1,
              entry.snapshot.rates.allSatisfy({ ExchangeRateValidation.fiatCodes.contains($0.key)
                  && ExchangeRateValidation.isValid($0.value) }) else { return false }
        return entry.snapshot.source == "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@\(date)/v1/currencies/usd.min.json"
            || entry.snapshot.source == "https://\(date).currency-api.pages.dev/v1/currencies/usd.min.json"
    }

    private func readCache(for date: String) -> CacheEntry? {
        let url = storageURL.appendingPathComponent("\(date).json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_000_000, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: data)
    }

    private func writeCache(_ entry: CacheEntry, for date: String) {
        // A cache write failure must not invalidate a successfully fetched table.
        // The in-memory cache remains usable; expired disk entries are never used.
        do {
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entry)
            try data.write(to: storageURL.appendingPathComponent("\(date).json"), options: .atomic)
        } catch { }
    }

    private struct APIPayload: Decodable {
        let date: String
        let usd: [String: Decimal]
    }

    private struct CacheEntry: Codable {
        let fetchedAt: Date
        let snapshot: CurrencyRateSnapshot
    }
}

private enum ExchangeRateValidation {
    static let fiatCodes = Set(Locale.commonISOCurrencyCodes + ["RUB", "BAM"])

    static func isValid(_ rate: Decimal) -> Bool { !rate.isNaN && rate > 0 }

    static func validateDate(_ date: String, now: Date) throws {
        guard date.utf8.count == 10,
              date.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
            throw ExchangeRateError.invalidDate
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date,
              parsed <= calendar.startOfDay(for: now) else { throw ExchangeRateError.invalidDate }
    }
}

enum ExchangeRateError: LocalizedError {
    case invalidDate, unsupportedCurrency, invalidResponse, wrongDate
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidDate: return "Choose a valid date in yyyy-MM-dd format that is not in the future."
        case .unsupportedCurrency: return "An exchange rate is not available for one of these currencies."
        case .invalidResponse: return "The exchange-rate table contains invalid rates. Try again later."
        case .wrongDate: return "The provider returned rates for a different date. No conversion was performed."
        case .unavailable(let date): return "Exchange rates for \(date) are unavailable. Check your connection or try again later. Cached rates from another day will not be used."
        }
    }
}
