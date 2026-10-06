import Foundation
import Testing
@testable import Expenso

@Suite("Currency picker — search, grouping and local recency")
struct CurrencyPickerTests {
    private func archive(_ codes: [String]) throws -> Data { try JSONEncoder().encode(codes) }
    private func allCodes(_ groups: CurrencyPickerGroups) -> [String] {
        (groups.base + groups.recent + groups.other).map(\.code)
    }

    @Test("Search accepts codes, English names and normalized input", arguments: [
        ("rUb", "RUB"), ("  RUB\n", "RUB"), ("russian", "RUB"),
        ("RÚSSIAN", "RUB"), ("convertible", "BAM"), ("euro", "EUR")
    ])
    func search(_ query: String, expectedCode: String) {
        let groups = CurrencyPickerCatalog.groups(base: "RUB", recent: ["BAM"], search: query)
        #expect(allCodes(groups).contains(expectedCode))
    }

    @Test("Search filters base, recent and other sections consistently")
    func sectionSearch() {
        let euro = CurrencyPickerCatalog.groups(base: "RUB", recent: ["BAM", "USD"], search: "EUR")
        #expect(euro.base.isEmpty)
        #expect(euro.recent.isEmpty)
        #expect(euro.other.map(\.code) == ["EUR"])
        #expect(!euro.isEmpty)
        let missing = CurrencyPickerCatalog.groups(base: "RUB", recent: ["BAM"], search: "not-a-currency-zzzzz")
        #expect(missing.base.isEmpty && missing.recent.isEmpty && missing.other.isEmpty)
        #expect(missing.isEmpty)
    }

    @Test("Whitespace-only queries preserve the full grouped catalog")
    func emptySearch() {
        let groups = CurrencyPickerCatalog.groups(base: "RUB", recent: ["BAM"], search: " \n\t ")
        #expect(groups.base.map(\.code) == ["RUB"])
        #expect(groups.recent.map(\.code) == ["BAM"])
        #expect(Set(allCodes(groups)) == Set(CurrencyPickerCatalog.entries.map(\.code)))
    }

    @Test("Base is pinned once and recent order does not reorder the remaining catalog")
    func grouping() {
        let groups = CurrencyPickerCatalog.groups(base: "RUB", recent: ["BAM", "USD", "BAM", "RUB", "INVALID", "EUR"], search: "")
        #expect(groups.base.map(\.code) == ["RUB"])
        #expect(groups.recent.map(\.code) == ["BAM", "USD", "EUR"])
        #expect(groups.other.map(\.code) == groups.other.map(\.code).sorted())
        #expect(!groups.other.contains { ["RUB", "BAM", "USD", "EUR"].contains($0.code) })
        let codes = allCodes(groups)
        #expect(Set(codes).count == codes.count)
        #expect(Set(codes) == Set(CurrencyPickerCatalog.entries.map(\.code)))
    }

    @Test("Changing base preserves recency while preventing duplicate base rows")
    func baseChanges() {
        let rub = CurrencyPickerCatalog.groups(base: "RUB", recent: ["BAM", "RUB", "USD"], search: "")
        let bam = CurrencyPickerCatalog.groups(base: "BAM", recent: ["BAM", "RUB", "USD"], search: "")
        #expect(rub.recent.map(\.code) == ["BAM", "USD"])
        #expect(bam.base.map(\.code) == ["BAM"])
        #expect(bam.recent.map(\.code) == ["RUB", "USD"])
        #expect(Set(allCodes(bam)).count == allCodes(bam).count)
    }

    @Test("An unsupported base falls back to RUB")
    func invalidBase() {
        let groups = CurrencyPickerCatalog.groups(base: "INVALID", recent: ["RUB", "BAM"], search: "")
        #expect(groups.base.map(\.code) == ["RUB"])
        #expect(groups.recent.map(\.code) == ["BAM"])
    }

    @Test("History decoding normalizes, validates, deduplicates and caps in order")
    func decodeHistory() throws {
        let data = try archive([" bam ", "usd", "BAM", "INVALID", "eur", " rub\n", "GBP", "CAD", "JPY"])
        #expect(CurrencyPickerHistory.limit == 6)
        #expect(CurrencyPickerHistory.decode(data) == ["BAM", "USD", "EUR", "RUB", "GBP", "CAD"])
    }

    @Test("Recent display is bounded even for unsanitized caller input")
    func boundedGroups() {
        let groups = CurrencyPickerCatalog.groups(base: "RUB", recent: ["BAM", "USD", "EUR", "GBP", "CAD", "JPY", "AUD", "USD"], search: "")
        #expect(groups.recent.map(\.code) == ["BAM", "USD", "EUR", "GBP", "CAD", "JPY"])
        #expect(groups.other.contains { $0.code == "AUD" })
    }

    @Test("Malformed and wrong-shaped history archives are empty", arguments: [
        "", "not-json", "{}", "null", "[1,2]", "[\"USD\",42]", "\"USD\""
    ])
    func corruptHistory(_ payload: String) {
        #expect(CurrencyPickerHistory.decode(Data(payload.utf8)).isEmpty)
    }

    @Test("A valid choice moves to the front, round-trips and evicts the oldest")
    func recording() throws {
        let original = try archive(["BAM", "USD", "EUR", "GBP", "CAD", "JPY"])
        let reused = CurrencyPickerHistory.recording(" usd ", in: original)
        #expect(CurrencyPickerHistory.decode(reused) == ["USD", "BAM", "EUR", "GBP", "CAD", "JPY"])
        let new = CurrencyPickerHistory.recording("RUB", in: reused)
        #expect(CurrencyPickerHistory.decode(new) == ["RUB", "USD", "BAM", "EUR", "GBP", "CAD"])
        #expect(try JSONDecoder().decode([String].self, from: new) == ["RUB", "USD", "BAM", "EUR", "GBP", "CAD"])
        #expect(CurrencyPickerHistory.decode(CurrencyPickerHistory.recording("RUB", in: new)) == ["RUB", "USD", "BAM", "EUR", "GBP", "CAD"])
    }

    @Test("Valid recording recovers corrupt history but invalid choices preserve raw data")
    func invalidRecording() {
        let corrupt = Data("not-json".utf8)
        #expect(CurrencyPickerHistory.recording("INVALID", in: corrupt) == corrupt)
        #expect(CurrencyPickerHistory.recording("  ", in: corrupt) == corrupt)
        #expect(CurrencyPickerHistory.decode(CurrencyPickerHistory.recording("EUR", in: corrupt)) == ["EUR"])
    }

    @Test("Representative flags and shared-currency fallback remain explicit", arguments: [
        ("RUB", "🇷🇺"), ("BAM", "🇧🇦"), ("EUR", "🇪🇺"), ("XOF", "🌐")
    ])
    func emoji(_ code: String, expected: String) throws {
        let entry = try #require(CurrencyPickerCatalog.entries.first { $0.code == code })
        #expect(entry.emoji == expected)
        #expect(entry.id == code)
        #expect(!entry.name.isEmpty)
    }
}
