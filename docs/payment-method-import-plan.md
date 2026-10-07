# Optional payment method on imported transactions

Date: October 7, 2026. Status: implemented locally; independent review, simulator regression tests, and Release simulator build completed.

## Behavior

AI may suggest one payment method per imported transaction: **Card**, **Crypto**, or **Cash**. The field is optional. An absent, unclear, conflicting, mixed, or unsupported method remains **Not specified** and never blocks saving.

The model decides from the transaction's meaning and context across languages. Do not introduce merchant rules, bank templates, or keyword/regular-expression classifiers. Validate its output against the three supported values. Uncertainty is an ordinary empty value, not a required review warning.

For the supplied input:

> Karta *7177. Xarid/Pokupka "Konzum BIH P-153>MOS", -0.85, BAM, "07-10-2026 19:08". Dostupno: 119.41, USD.

Expected suggestion: **Card**, based on the card reference and purchase context. The purchase is **0.85 BAM**; **119.41 USD** is an available balance, not another transaction. The card suffix is context for the AI; v1 stores only the method.

Additional boundaries:

- A purchase paid with crypto can suggest Crypto. Buying crypto with a card should suggest Card when that payment is explicit.
- A cash withdrawal alone does not establish that a later purchase was paid in cash.
- An ordinary merchant name or a currency alone does not establish a payment method.
- Multiple imported rows receive independent suggestions; do not copy one row's method to the whole batch.
- Keep existing amount, currency, date, direction, and category validation unchanged. This feature does not add crypto asset accounting or currency support.

## Review and editing

Add one native menu row, **Payment method**, to import verification and the existing transaction editor. Choices: Not specified, Card, Crypto, Cash. Prefill new import drafts with the AI suggestion; allow changing or clearing it before saving. Manual transactions start with Not specified.

For import into an existing transaction, retain its current method by default. If its method is empty, use the new suggestion. An explicit review edit or clear takes precedence; an absent AI suggestion must not erase a saved value. Show a saved method in transaction details when present. Reuse the existing glass styling and form components.

No new settings screen, required selection, confidence score, account/card management, historical reclassification, payment filters, charts, or chat tools in this increment.

## Implementation sequence

1. **Shared value and storage.** Add a small `PaymentMethod` enum (`card`, `crypto`, `cash`) with display labels and optional raw-string persistence. Add an optional attribute in a new Core Data model version, retaining the older models. Existing records resolve to nil. Use the existing migration mechanism without changing its configuration; include the schema addition in implementation approval.
2. **AI suggestions.** Extend both text and image prompts and the decoded candidate in `RemoteReceiptInference.swift` with `paymentMethod`. Missing, null, unsupported, or malformed method values resolve to nil without invalidating otherwise valid transactions. For Apple Intelligence, expand the existing category suggestion pass in `ReceiptInterpreter.swift` to return category and payment method together, avoiding an extra model request. Payment inference must still work when no category can be suggested. If the model is unavailable or fails, leave the method empty; the basic parser does not classify it.
3. **Draft and UI flow.** Carry the optional value through `RemoteImageTransaction`, candidate creation, review state, draft application, save, edit hydration, rollback, and pristine-draft detection. Add the review/editor menu and optional detail row. Preserve existing cancellation and provider-change guards.
4. **Data preservation.** Include the raw field in ledger snapshots, delete/undo restoration, retained-byte accounting, and edit-conflict revisions. Extend CSV with a payment-method column. Introduce backup format v3 for the new field while continuing to read v1/v2 as unspecified and preserving their checksum encoding. Recovery archives must retain the method too. Follow existing model-capability checks when accessing legacy stores, and reject a restore into a schema that cannot preserve the incoming field.
5. **Review and documentation.** Update `docs/receipt-scanning.md`, obtain an independent local review, and address actionable findings before delivery.

Primary integration points: `RemoteReceiptInference.swift`, `ReceiptInterpreter.swift`, `ReceiptImportView.swift`, `RemoteTransactionReviewView.swift`, `AddExpenseViewModel.swift`, `AddExpenseView.swift`, `ExpenseDetailedView.swift`, `ExpenseCD.swift`, the versioned Core Data model, `LedgerRecord`, `LedgerMutationService`, `LedgerBackupService`, `TransactionRevision`, and `ExpenseCSVModel.swift`.

## Verification proposed for implementation

The implementation approval includes the focused simulator checks and build below. Live AI and physical-device verification remain separate.

- Mock AI collaborators for deterministic tests of card/crypto/cash, omitted/null/invalid methods, mixed methods, independent batch values, and preservation of existing financial fields. Include the supplied bank message as a fixture. These tests establish the response contract, not real model accuracy.
- Cover changing and clearing suggestions, saving with no method, retaining an existing method, and preventing state leakage between candidates.
- Verify save/reload, edit rollback/conflict handling, delete/undo, CSV output, v3 backup round-trip, and v1/v2 compatibility on disposable data.
- Verify migration from the existing V2 SQLite store preserves transactions and leaves their method empty. Include the older supported migration path where covered by existing fixtures. Use V3 for current feature fixtures while keeping explicit V1/V2 compatibility fixtures.
- Use XcodeBuildMCP for authorized focused tests and a simulator build. Separately verify the review menu and real AI inference with representative multilingual inputs when runtime analysis is authorized; mock tests and a build do not establish model accuracy or device behavior.

## Verification results

- XcodeBuildMCP unit/integration suite on iPhone 18 Pro, iOS 27 simulator: 336 passed, 1 skipped, 0 failed.
- A context-specific entity lookup removed Core Data ambiguity exposed by loading multiple model versions in the tests. The 44 affected editor, draft, category, and currency checks all passed after that final adjustment.
- Release simulator build passed. Existing deprecation warnings in unrelated helper files remain.
- Independent local review completed with no remaining actionable findings. An identified unknown-value preservation issue was fixed and covered before completion.
- A focused XCTest UI check passed on the isolated simulator app: all four payment menu choices, clearing, import cancellation preserving the selection, and canceled drafts leaving new transactions unspecified.
- Live AI inference, candidate-to-candidate navigation, and physical-device behavior were not exercised. AI tests use mocked collaborators and establish response handling, not model accuracy.
- No deployment performed.
