import SwiftUI

struct CurrencyPickerEntry: Identifiable {
    let code: String
    let name: String
    let emoji: String
    let searchText: String
    var id: String { code }
}

struct CurrencyPickerGroups {
    let base: [CurrencyPickerEntry]
    let recent: [CurrencyPickerEntry]
    let other: [CurrencyPickerEntry]
    var isEmpty: Bool { base.isEmpty && recent.isEmpty && other.isEmpty }
}

/// Value-only catalog: no locale lookups, ledger fetches, or formatting while typing.
enum CurrencyPickerCatalog {
    private static let searchLocale = Locale(identifier: "en_US_POSIX")
    private static let flags = [
        "AED": "🇦🇪", "AFN": "🇦🇫", "ALL": "🇦🇱", "AMD": "🇦🇲", "ANG": "🌐",
        "AOA": "🇦🇴", "ARS": "🇦🇷", "AUD": "🇦🇺", "AZN": "🇦🇿", "BAM": "🇧🇦",
        "BDT": "🇧🇩", "BGN": "🇧🇬", "BHD": "🇧🇭", "BRL": "🇧🇷", "BYN": "🇧🇾",
        "CAD": "🇨🇦", "CHF": "🇨🇭", "CLP": "🇨🇱", "CNY": "🇨🇳", "COP": "🇨🇴",
        "CRC": "🇨🇷", "CZK": "🇨🇿", "DKK": "🇩🇰", "DOP": "🇩🇴", "DZD": "🇩🇿",
        "EGP": "🇪🇬", "EUR": "🇪🇺", "GBP": "🇬🇧", "GEL": "🇬🇪", "GHS": "🇬🇭",
        "HKD": "🇭🇰", "HUF": "🇭🇺", "IDR": "🇮🇩", "ILS": "🇮🇱", "INR": "🇮🇳",
        "IQD": "🇮🇶", "IRR": "🇮🇷", "ISK": "🇮🇸", "JOD": "🇯🇴", "JPY": "🇯🇵",
        "KES": "🇰🇪", "KGS": "🇰🇬", "KHR": "🇰🇭", "KRW": "🇰🇷", "KWD": "🇰🇼",
        "KZT": "🇰🇿", "LAK": "🇱🇦", "LBP": "🇱🇧", "LKR": "🇱🇰", "MAD": "🇲🇦",
        "MDL": "🇲🇩", "MKD": "🇲🇰", "MNT": "🇲🇳", "MXN": "🇲🇽", "MYR": "🇲🇾",
        "NGN": "🇳🇬", "NOK": "🇳🇴", "NPR": "🇳🇵", "NZD": "🇳🇿", "OMR": "🇴🇲",
        "PEN": "🇵🇪", "PHP": "🇵🇭", "PKR": "🇵🇰", "PLN": "🇵🇱", "QAR": "🇶🇦",
        "RON": "🇷🇴", "RSD": "🇷🇸", "RUB": "🇷🇺", "SAR": "🇸🇦", "SEK": "🇸🇪",
        "SGD": "🇸🇬", "THB": "🇹🇭", "TJS": "🇹🇯", "TMT": "🇹🇲", "TND": "🇹🇳",
        "TRY": "🇹🇷", "TWD": "🇹🇼", "UAH": "🇺🇦", "USD": "🇺🇸", "UYU": "🇺🇾",
        "UZS": "🇺🇿", "VND": "🇻🇳", "ZAR": "🇿🇦"
    ]

    static let entries: [CurrencyPickerEntry] = CurrencySettings.codes.map { code in
        let name = CurrencySettings.names[code] ?? code
        return CurrencyPickerEntry(code: code, name: name, emoji: flags[code] ?? "🌐",
                                   searchText: normalized("\(code) \(name)"))
    }
    private static let byCode = Dictionary(uniqueKeysWithValues: entries.map { ($0.code, $0) })

    static func groups(base: String, recent: [String], search: String) -> CurrencyPickerGroups {
        let baseCode = byCode[base] == nil ? "RUB" : base
        let query = normalized(search)
        let recentCodes = CurrencyPickerHistory.sanitized(recent).filter { $0 != baseCode }
        let pinned = Set([baseCode] + recentCodes)
        func matches(_ entry: CurrencyPickerEntry) -> Bool {
            query.isEmpty || entry.searchText.contains(query)
        }
        return CurrencyPickerGroups(
            base: [byCode[baseCode]].compactMap { $0 }.filter(matches),
            recent: recentCodes.compactMap { byCode[$0] }.filter(matches),
            other: entries.filter { !pinned.contains($0.code) && matches($0) })
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: searchLocale)
    }
}

/// Picker preferences only; selection never writes to the base currency or the ledger.
enum CurrencyPickerHistory {
    static let key = "recentCurrencyPickerCodes.v1"
    static let limit = 6
    private static let supported = Set(CurrencySettings.codes)

    static func decode(_ data: Data) -> [String] {
        guard data.count <= 16_384, let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return sanitized(values)
    }

    static func recording(_ code: String, in data: Data) -> Data {
        guard let code = sanitized([code]).first else { return data }
        return (try? JSONEncoder().encode(sanitized([code] + decode(data)))) ?? data
    }

    static func sanitized(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in codes {
            let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard supported.contains(code), seen.insert(code).inserted else { continue }
            result.append(code)
            if result.count == limit { break }
        }
        return result
    }
}

struct CurrencyPickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CurrencySettings.key) private var baseCurrency = "RUB"
    @AppStorage(CurrencyPickerHistory.key) private var recentData = Data()
    @State private var search = ""
    var title = "Currency"

    var body: some View {
        let groups = CurrencyPickerCatalog.groups(base: baseCurrency,
            recent: CurrencyPickerHistory.decode(recentData), search: search)
        NavigationStack {
            List {
                if !groups.base.isEmpty {
                    Section("Base Currency") { rows(groups.base) }
                }
                if !groups.recent.isEmpty {
                    Section("Recently Used") { rows(groups.recent) }
                }
                if !groups.other.isEmpty {
                    Section("All Currencies") { rows(groups.other) }
                }
            }
            .overlay {
                if groups.isEmpty { ContentUnavailableView.search(text: search) }
            }
            .searchable(text: $search, prompt: "Code or currency name")
            .autocorrectionDisabled()
            .scrollDismissesKeyboard(.interactively)
            .expenseScreenChrome()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
        }
    }

    private func rows(_ entries: [CurrencyPickerEntry]) -> some View {
        ForEach(entries) { entry in
            Button {
                recentData = CurrencyPickerHistory.recording(entry.code, in: recentData)
                selection = entry.code
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Text(entry.emoji).font(.title2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.code).font(.body.weight(.medium))
                        Text(entry.name).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if selection == entry.code {
                        Image(systemName: "checkmark").accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("\(entry.code), \(entry.name)")
            .accessibilityAddTraits(selection == entry.code ? .isSelected : [])
        }
    }
}
