import Foundation
import Testing
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Expenso

/// Local clipboard integration only; image preparation never invokes inference.
@MainActor
@Suite("Unified import clipboard — no network or ledger access", .serialized)
struct ReceiptImportClipboardTests {
    @Test func imagePasteRemainsAvailableWhenUIKitSuggestsOnlyAutofill() throws {
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in }
        let editor = ReceiptPasteEditor.PasteTextView()
        let autofill = UIMenu(title: "AutoFill", children: [UIAction(title: "Contact") { _ in }])
        let menu = try #require(editor.editMenuInteraction(UIEditMenuInteraction(delegate: editor),
            menuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero), suggestedActions: [autofill]))
        #expect(menu.children.contains { ($0 as? UICommand)?.action == #selector(UIResponderStandardEditActions.paste(_:)) })
        #expect(menu.children.contains { $0 === autofill })
    }

    @Test func systemImagePasteProvidersReachImportInsteadOfTextInsertion() {
        let editor = ReceiptPasteEditor.PasteTextView()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in }
        let provider = NSItemProvider(object: image)
        var received: NSItemProvider?
        editor.onImagePaste = { received = $0 }
        #expect(editor.canPaste([provider]))
        editor.paste(itemProviders: [provider])
        #expect(received === provider)
        #expect(editor.text.isEmpty)
        editor.isEditable = false
        received = nil
        #expect(!editor.canPaste([provider]))
        editor.paste(itemProviders: [provider])
        #expect(received == nil)
    }

    @Test func existingNativePasteCommandIsPreservedWhenTextIsSelected() throws {
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in }
        let editor = ReceiptPasteEditor.PasteTextView()
        editor.text = "Existing draft"
        let paste = UICommand(title: "Paste", action: #selector(UIResponderStandardEditActions.paste(_:)))
        let systemMenu = UIMenu(children: [paste])
        let menu = try #require(editor.importPasteMenu(suggestedActions: [systemMenu]))
        #expect(menu.children.count == 1)
        #expect(menu.children.first === systemMenu)
    }

    private func waitForCompletion(_ model: ReceiptImportModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while model.isReading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isReading)
    }

    @Test func combinesTextItems() async throws {
        let model = ReceiptImportModel()
        var text = "original"
        model.paste([NSItemProvider(object: "Taxi, 125 RUB" as NSString),
                     NSItemProvider(object: "Coffee, 100 RUB" as NSString)],
                    remotely: true, revision: OpenRouterSettings.shared.revision) { text = $0 }
        try await waitForCompletion(model)
        #expect(text == "Taxi, 125 RUB\nCoffee, 100 RUB")
        #expect(model.error == nil && model.remoteResult == nil)
    }

    @Test func oversizedReplacementPreservesImageAndText() async throws {
        let model = ReceiptImportModel()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        model.read(image, remotely: true, revision: OpenRouterSettings.shared.revision)
        try await waitForCompletion(model)
        let prepared = try #require(model.preparedImage)
        var text = "existing draft"
        model.paste([NSItemProvider(object: String(repeating: "я", count: 12_001) as NSString)],
                    remotely: true, revision: OpenRouterSettings.shared.revision) { text = $0 }
        try await waitForCompletion(model)
        #expect(text == "existing draft")
        #expect(model.preparedImage == prepared && model.error != nil)
    }

    @Test func combinedByteLimitIsEnforced() async throws {
        let model = ReceiptImportModel()
        var text = "existing draft"
        let item = String(repeating: "a", count: 12_000) as NSString
        model.paste([NSItemProvider(object: item), NSItemProvider(object: item)],
                    remotely: true, revision: OpenRouterSettings.shared.revision) { text = $0 }
        try await waitForCompletion(model)
        #expect(text == "existing draft" && model.error != nil)
    }

    @Test func cancelledPasteCannotReplaceInput() async throws {
        let model = ReceiptImportModel()
        var text = "existing draft"
        model.paste([NSItemProvider(object: "replacement" as NSString)],
                    remotely: true, revision: OpenRouterSettings.shared.revision) { text = $0 }
        model.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(text == "existing draft" && !model.isReading)
    }

    @Test func imageObjectProviderPreparesImageWithoutInference() async throws {
        let model = ReceiptImportModel()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        model.read(NSItemProvider(object: image), remotely: true, revision: OpenRouterSettings.shared.revision)
        try await waitForCompletion(model)
        #expect(model.preparedImage != nil && model.error == nil && model.remoteResult == nil)
    }

    @Test func cancelledImageProviderCannotPublishImage() async throws {
        let model = ReceiptImportModel()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { _ in }
        model.read(NSItemProvider(object: image), remotely: true, revision: OpenRouterSettings.shared.revision)
        model.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.preparedImage == nil && model.remoteResult == nil && !model.isReading)
    }
}

@Suite("Image and text transaction inference — mocked AI, no ledger access")
struct RemoteReceiptInferenceTests {
    private let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
    private func reply(_ rows: String, warnings: String = "[]", tooMany: Bool = false) -> String {
        "{\"transactions\":[\(rows)],\"warnings\":\(warnings),\"tooMany\":\(tooMany)}"
    }
    private let row = #"{"title":"аренда","amount":"59500.00","currency":"RUB","date":"2026-10-04","type":"expense","category":"travel","warnings":[]}"#

    @Test("Optional malformed payment metadata never rejects or changes a valid transaction",
          arguments: ["missing", "null", #""wire""#, #""Card""#, "\"\"", "42", "true", "{}", #"["card","cash"]"#])
    func optionalPaymentMethodValidation(_ value: String) throws {
        let baseline = try RemoteReceiptInference.decode(reply(row), imageData: jpeg, categories: CategoryCatalog.defaults).transactions[0]
        let candidate = value == "missing" ? row : String(row.dropLast()) + ",\"paymentMethod\":\(value)}"
        let transaction = try RemoteReceiptInference.decode(reply(candidate), imageData: jpeg, categories: CategoryCatalog.defaults).transactions[0]
        #expect(transaction.paymentMethod == nil)
        #expect(transaction.title == baseline.title && transaction.amount == baseline.amount)
        #expect(transaction.currency == baseline.currency && transaction.date == baseline.date)
        #expect(transaction.type == baseline.type && transaction.category == baseline.category)
        #expect(transaction.warnings == baseline.warnings)
    }

    @Test("Bank-message fixture keeps the AI card suggestion and the original purchase amount")
    func bankMessagePaymentSuggestion() async throws {
        let input = #"Karta *7177. Xarid/Pokupka "Konzum BIH P-153>MOS", -0.85, BAM, "07-10-2026 19:08". Dostupno: 119.41, USD."#
        let expected = reply(#"{"title":"Konzum BIH P-153>MOS","amount":"0.85","currency":"BAM","date":"2026-10-07","type":"expense","category":null,"paymentMethod":"card","warnings":[]}"#)
        let service = RemoteReceiptInference(textCompletion: { _, _, messages in
            #expect(messages.last?.content == input)
            return expected
        })
        let result = try await service.extract(text: input, apiKey: "fixture-only", categories: [])
        let transaction = try #require(result.transactions.first)
        #expect(result.transactions.count == 1 && result.sourceText == input)
        #expect(transaction.paymentMethod == .card && transaction.amount == "0.85")
        #expect(transaction.currency == "BAM" && transaction.type == TRANS_TYPE_EXPENSE)
        #expect(transaction.date.map(Money.day) == "2026-10-07" && transaction.warnings.isEmpty)
    }

    @Test("Both remote paths preserve independent card, crypto, cash and unspecified decisions", arguments: ["image", "text"])
    func independentPaymentSuggestions(_ source: String) async throws {
        let rows = [
            ("Crypto bought with card", #""card""#),
            ("Purchase paid with crypto", #""crypto""#),
            ("Purchase paid with cash", #""cash""#),
            ("Cash withdrawal then an unspecified purchase", "null"),
            ("Mixed cash and card payment", "null"),
            ("Ordinary merchant with currency only", "null")
        ].map { title, method in
            #"{"title":"\#(title)","amount":"10","currency":"EUR","date":"2026-10-07","type":"expense","category":null,"paymentMethod":\#(method),"warnings":[]}"#
        }
        let expected = reply(rows.joined(separator: ","))
        let validate: @Sendable ([OpenRouterMessage]) throws -> Void = { messages in
            let system = try #require(messages.first?.content)
            #expect(system.contains("paymentMethod") && system.contains("independently for each transaction"))
            #expect(system.contains("purchasing crypto with an explicitly used card is card"))
            #expect(system.contains("cash withdrawal") && system.contains("merchant name or currency alone"))
            #expect(system.contains("mixed") && system.contains("use null without adding a warning"))
        }
        let service = RemoteReceiptInference(completion: { _, _, messages, _ in
            #expect(source == "image")
            try validate(messages)
            return expected
        }, textCompletion: { _, _, messages in
            #expect(source == "text")
            try validate(messages)
            return expected
        })
        let result: RemoteImageTransactions
        if source == "image" {
            result = try await service.extract(imageData: jpeg, apiKey: "fixture-only", categories: [])
        } else {
            result = try await service.extract(text: "Independent transaction fixture", apiKey: "fixture-only", categories: [])
        }
        #expect(result.transactions.map(\.paymentMethod) == [.card, .crypto, .cash, nil, nil, nil])
        #expect(result.transactions.allSatisfy { $0.warnings.isEmpty && $0.category == nil && $0.amount == "10" })
    }

    @Test func screenshotMultipleTransactions() throws {
        let incoming = #"{"title":"Refund","amount":"12.50","currency":"EUR","date":"2026-10-03","type":"income","category":null,"warnings":[]}"#
        let result = try RemoteReceiptInference.decode(reply(row + "," + incoming), imageData: jpeg, categories: CategoryCatalog.defaults)
        #expect(result.transactions.count == 2 && result.transactions[0].amount == "59500")
        #expect(result.transactions[0].currency == "RUB" && result.transactions[0].category == "travel")
        #expect(result.transactions[1].type == "income" && result.transactions[1].currency == "EUR")
        #expect(Set(result.transactions.map(\.id)).count == 2)
    }

    @Test func missingFieldsNeverDefaultToBaseOrToday() throws {
        let unknown = #"{"title":null,"amount":null,"currency":"$","date":"2026-02-30","type":"transfer","category":"not-real","warnings":[]}"#
        let result = try RemoteReceiptInference.decode(reply(unknown), imageData: jpeg, categories: CategoryCatalog.defaults)
        let transaction = try #require(result.transactions.first)
        #expect(transaction.title == nil && transaction.amount == nil && transaction.currency == nil)
        #expect(transaction.type == nil && transaction.date == nil && transaction.category == nil)
        #expect(transaction.warnings.count >= 4)
    }

    @Test func invalidAmountsAreRejectedBeforeReview() throws {
        for value in ["-12", "1,200.50", "1e5", "NaN", "0", "１２", "1.000000001"] {
            let invalid = row.replacingOccurrences(of: "59500.00", with: value)
            #expect(throws: RemoteReceiptError.self) { try RemoteReceiptInference.decode(reply(invalid), imageData: jpeg, categories: CategoryCatalog.defaults) }
        }
    }

    @Test func boundsAndEmptyResults() throws {
        #expect(throws: RemoteReceiptError.self) { try RemoteReceiptInference.decode(reply(""), imageData: jpeg, categories: []) }
        #expect(throws: RemoteReceiptError.self) { try RemoteReceiptInference.decode(reply("", tooMany: true), imageData: jpeg, categories: []) }
        #expect(throws: RemoteReceiptError.self) { try RemoteReceiptInference.decode(reply(Array(repeating: row, count: 31).joined(separator: ",")), imageData: jpeg, categories: []) }
        #expect(throws: RemoteReceiptError.self) { try RemoteReceiptInference.decode(String(repeating: "a", count: 65_537), imageData: jpeg, categories: []) }
        #expect(throws: RemoteReceiptError.self) { try RemoteReceiptInference.decode(reply(row, warnings: "[\"" + String(repeating: "a", count: 301) + "\"]"), imageData: jpeg, categories: []) }
    }

    @Test func archivedCategoryNotSuggested() throws {
        var archived = try #require(CategoryCatalog.defaults.first { $0.id == "travel" })
        archived.isArchived = true
        let result = try RemoteReceiptInference.decode(reply(row), imageData: jpeg, categories: [archived])
        #expect(result.transactions[0].category == nil)
    }

    @Test func serviceUsesDedicatedModelAndNoLedgerContext() async throws {
        let expected = reply(row)
        let service = RemoteReceiptInference { key, model, messages, image in
            #expect(key == "fixture-only" && model == "google/gemini-2.5-flash")
            #expect(image == Data([0xff, 0xd8, 0xff, 0xd9]))
            #expect(messages.count == 2 && messages.last?.role == "user")
            #expect(messages.first?.content?.contains("balances") == true)
            return expected
        }
        let result = try await service.extract(imageData: jpeg, apiKey: "fixture-only", categories: CategoryCatalog.defaults)
        #expect(result.transactions.count == 1)
    }

    @MainActor @Test func preparationResizesAndDoesNotUpload() async throws {
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 2600, height: 1200)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2600, height: 1200))
        }
        let sourcePNG = try #require(rendered.pngData())
        let sourceImage = try #require(CGImageSourceCreateWithData(sourcePNG as CFData, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(sourceImage, 0, nil))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                          kCGImagePropertyGPSLongitude: 0.1, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Private metadata fixture"]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let data = encoded as Data
        let inputSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let inputProperties = try #require(CGImageSourceCopyPropertiesAtIndex(inputSource, 0, nil) as? [CFString: Any])
        #expect(inputProperties[kCGImagePropertyGPSDictionary] != nil)
        let service = RemoteReceiptInference { _, _, _, _ in Issue.record("Preparation must not upload"); return "" }
        let prepared = try await service.prepare(data: data)
        #expect(prepared.starts(with: [0xff, 0xd8, 0xff]) && prepared.count <= 3 * 1_024 * 1_024)
        let source = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 0) <= 2400)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] == nil)
    }

    @Test func invalidInputNeverReachesInference() async throws {
        let service = RemoteReceiptInference { _, _, _, _ in Issue.record("Invalid image must not upload"); return "" }
        do { _ = try await service.prepare(data: Data("not an image".utf8)); Issue.record("Expected invalid image") }
        catch { #expect(error is ReceiptScanError) }
        do { _ = try await service.extract(imageData: Data([1, 2, 3]), apiKey: "fixture", categories: []); Issue.record("Expected invalid upload") }
        catch { #expect(error is RemoteReceiptError) }
    }

    @Test("Text import uses only submitted text and categories with the selected model")
    func textMultipleTransactions() async throws {
        let input = "2026-10-04,аренда,-59500.00,RUB\n2026-10-03,Refund,+12.50,EUR\nAvailable balance 90000 RUB"
        let incoming = #"{"title":"Refund","amount":"12.50","currency":"EUR","date":"2026-10-03","type":"income","category":null,"warnings":[]}"#
        let expected = reply(row + "," + incoming)
        let service = RemoteReceiptInference(completion: { _, _, _, _ in
            Issue.record("Text must not invoke image completion"); return ""
        }, textCompletion: { key, model, messages in
            #expect(key == "fixture-only" && model == "openai/gpt-5-mini")
            #expect(messages.count == 3 && messages.last?.role == "user" && messages.last?.content == input)
            let system = try #require(messages.first?.content)
            #expect(system.contains("UNTRUSTED DATA") && system.contains("balances") && system.contains("pending"))
            #expect(system.contains("tooMany:true") && system.contains("inferred sums"))
            #expect(messages.allSatisfy { $0.tool_calls == nil && $0.tool_call_id == nil })
            #expect(!messages.compactMap(\.content).joined().contains("fixture-only"))
            return expected
        })
        let result = try await service.extract(text: input, apiKey: "fixture-only", categories: CategoryCatalog.defaults,
            model: "openai/gpt-5-mini")
        #expect(result.sourceText == input && result.imageData.isEmpty)
        #expect(result.transactions.count == 2 && Set(result.transactions.map(\.id)).count == 2)
        #expect(result.transactions[0].amount == "59500" && result.transactions[0].currency == "RUB")
        #expect(result.transactions[1].amount == "12.5" && result.transactions[1].type == "income")
    }

    @Test("Text import does not default missing amounts, currency, dates or directions")
    func textMissingFields() async throws {
        let expected = reply(#"{"title":"Unknown purchase","amount":null,"currency":null,"date":null,"type":null,"category":null,"warnings":[]}"#)
        let service = RemoteReceiptInference(textCompletion: { _, model, _ in
            #expect(model == OpenRouterClient.defaultModelID)
            return expected
        })
        let result = try await service.extract(text: "Unknown purchase", apiKey: "fixture", categories: [])
        let transaction = try #require(result.transactions.first)
        #expect(transaction.amount == nil && transaction.currency == nil && transaction.date == nil)
        #expect(transaction.type == nil && transaction.category == nil && transaction.warnings.count >= 4)
        #expect(result.sourceText == "Unknown purchase" && result.imageData.isEmpty)
    }

    @Test("Blank or oversized text is rejected before inference", arguments: ["blank", "whitespace", "oversized"])
    func invalidTextNeverReachesInference(_ scenario: String) async throws {
        let input = scenario == "blank" ? "" : scenario == "whitespace" ? " \n\t " : String(repeating: "💳", count: 6_001)
        let service = RemoteReceiptInference(textCompletion: { _, _, _ in
            Issue.record("Invalid input must not invoke completion"); return ""
        })
        do {
            _ = try await service.extract(text: input, apiKey: "fixture", categories: [])
            Issue.record("Expected invalid text")
        } catch RemoteReceiptError.invalidText {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("UTF-8 text exactly at the input bound remains valid")
    func textByteBoundary() async throws {
        let input = String(repeating: "💳", count: 6_000)
        let expected = reply(row)
        let service = RemoteReceiptInference(textCompletion: { _, _, messages in
            #expect(messages.last?.content?.utf8.count == 24_000)
            return expected
        })
        let result = try await service.extract(text: input, apiKey: "fixture", categories: [])
        #expect(result.sourceText == input && result.transactions.count == 1)
    }

    @Test("Text output validation rejects overflowing batches without truncation", arguments: [false, true])
    func textTooManyTransactions(_ flagged: Bool) async throws {
        let expected = flagged ? reply("", tooMany: true) : reply(Array(repeating: row, count: 31).joined(separator: ","))
        let service = RemoteReceiptInference(textCompletion: { _, _, _ in expected })
        do {
            _ = try await service.extract(text: "Many completed purchases", apiKey: "fixture", categories: [])
            Issue.record("Expected batch bound rejection")
        } catch RemoteReceiptError.tooManyTransactions {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("Cancellation before or after text inference never returns suggestions", arguments: [false, true])
    func textCancellation(_ duringCompletion: Bool) async throws {
        let expected = reply(row)
        let service = RemoteReceiptInference(textCompletion: { _, _, _ in
            #expect(duringCompletion)
            withUnsafeCurrentTask { $0?.cancel() }
            return expected
        })
        let task = Task {
            if !duringCompletion { withUnsafeCurrentTask { $0?.cancel() } }
            return try await service.extract(text: "Purchase 59500 RUB", apiKey: "fixture", categories: [])
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test("Text suggestions use the same strict amount validation as images")
    func textInvalidAmount() async throws {
        let expected = reply(row.replacingOccurrences(of: "59500.00", with: "1e5"))
        let service = RemoteReceiptInference(textCompletion: { _, _, _ in expected })
        do {
            _ = try await service.extract(text: "Purchase 1e5 RUB", apiKey: "fixture", categories: [])
            Issue.record("Expected invalid response")
        } catch RemoteReceiptError.invalidResponse {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("Semantic category suggestions use active custom categories without guessing financial fields", arguments: ["image", "text"])
    func automaticCategorySuggestion(_ source: String) async throws {
        let categories = [ExpenseCategory(id: "custom-food", name: "Cafes and groceries", symbol: "fork.knife")]
        let expected = reply(#"{"title":"Кофейня","amount":"250","currency":null,"date":null,"type":"expense","category":"custom-food","warnings":[]}"#)
        let validate: @Sendable ([OpenRouterMessage]) throws -> Void = { messages in
            let system = try #require(messages.first?.content)
            #expect(system.contains("Automatically suggest the best matching supplied active category ID"))
            #expect(system.contains("cafes and groceries") && system.contains("never invent an ID"))
            #expect(system.contains("must never be guessed"))
            #expect(messages.contains { $0.content?.contains("custom-food") == true })
        }
        let service = RemoteReceiptInference(completion: { _, _, messages, _ in
            #expect(source == "image")
            try validate(messages)
            return expected
        }, textCompletion: { _, _, messages in
            #expect(source == "text")
            try validate(messages)
            return expected
        })
        let result: RemoteImageTransactions
        if source == "image" {
            result = try await service.extract(imageData: jpeg, apiKey: "fixture", categories: categories)
        } else {
            result = try await service.extract(text: "Кофейня 250", apiKey: "fixture", categories: categories)
        }
        let transaction = try #require(result.transactions.first)
        #expect(transaction.category == "custom-food" && transaction.amount == "250")
        #expect(transaction.currency == nil && transaction.date == nil)
    }
}
