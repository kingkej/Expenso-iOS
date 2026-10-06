# Expenso: next-feature discussion plan

Date: October 4, 2026. Status: first implementation batch, personal category management, and an Insights/chart upgrade approved and implemented locally; remaining features are a roadmap.

## Direction

A private, native iPhone spending companion: quick to record, easy to inspect,
safe to recover, and able to explain spending with local, evidence-backed chat.
Keep English first, RUB as the existing ledger currency, and explicit review
before any imported or AI-suggested transaction is saved.

This research compares published first-party features, not hands-on competitor
testing, comparative OCR accuracy, or market-share claims. App Store marketing
research and monetization are intentionally out of scope for a personal app.
The initial research used available research support and a read-only source audit.
The approved first implementation batch continued in the same chat using Astra.

## Competitor lessons

| Reference | Verified published features | Suggested lesson for Expenso |
| --- | --- | --- |
| Dime | Category budgets, recurring expenses, quick actions, widgets, search by amount, undo deletion | Fast capture and small, legible budgeting UI |
| Copilot Money | Transaction review, spending line, monthly cash-flow summaries, subscriptions, budget rollover | Show what changed and what is due, with transaction drill-down |
| Money Manager / Realbyte | Monthly category budgets, transaction filters, monthly calendar, receipt photos | Make the existing ledger easy to search and inspect |
| Wallet / BudgetBakers | Planned payments/reminders, budgets, cash-flow insights, imports, multi-currency | Separate upcoming commitments from recorded spending |
| YNAB | Assign available money to purposes and save monthly for irregular expenses | Optional goals and annual-bill planning, without mandatory envelope budgeting |

First-party references consulted: Dime's US App Store listing; Copilot Money's
official feature page; realbyteapps.com; BudgetBakers' Wallet product page; and
YNAB's method page. Their advertised capabilities are inspiration, not evidence
that Expenso already implements them or a promise of equivalent behavior.

## Source baseline before the first batch

The current PR includes manual income/expenses, receipt drafts and attachments,
locked multi-currency conversion, CSV export, native Dashboard/Chat tabs,
biometrics, and read-only local spending chat with computed evidence.

Gaps identified from source:

- No full backup/restore. CSV is useful for exchange but omits attachments and
  cannot reconstruct the complete saved state.
- No dashboard search, arbitrary date ranges, multi-selection, or delete undo.
- Categories are fixed strings shared by UI, reports, and AI tool validation.
- No monthly budgets, recurring schedules, account relationships, or transfers.
- Chat exposes bounded transaction evidence but lacks full-result drill-down.
- Receipt review has no stored provenance or duplicate warning.
- The ledger's income-minus-expenses figure is net cash flow, not a reconciled
  bank/account balance; UI terminology should reflect that distinction.

## Recommended sequence

### 0. Finish the current release gate

Resolve actionable current-PR reviews and verify actual iPhone navigation,
receipt capture/photo import, local model availability, and spending chat.
Do not infer these runtime checks from simulator unit tests. Keep existing
migration evidence and a full backup before installing over the real app.

### 1. Recovery and everyday history — first implementation batch

1. Versioned local backup/restore including transactions, original amounts,
   currency snapshots, attachments, identifiers, and relevant app preferences.
   Save through Files; show validation and a restore preview. Do not overwrite
   the current ledger until a recovery path and explicit confirmation exist.
   A backup containing financial data needs an explicit protection policy;
   password encryption and automatic backup scheduling are separate choices.
2. Native searchable transaction history: title/note, category, type, original
   currency, amount range, calendar month, and custom date range. Show active
   filters and their exact totals. Add selection, bulk recategorization, and
   reversible deletion without changing locked rates.
3. Correct net-cash-flow terminology, avoiding any implication that the existing
   ledger contains current bank balances.

Implementation scope: full replacement restore needs no new model or migration.
Snapshot IDs validate archive uniqueness; restored records receive new Core Data
IDs. Merge imports and durable cross-restore deep links remain deferred and will
need a separately approved identity/migration design.

Implemented locally: Settings → Backup & Restore with native Files export/import,
version/checksum validation, preview, confirmation, and a device-local recovery
archive before a single-save replacement. Exported archives are not password
encrypted. They preserve raw fields, original currency metadata, receipt bytes,
base currency and accent; biometric preferences are not restored. Limits are
256 MB and 100,000 records. Save/read errors leave the current ledger intact.
Recovery archives remain local until exported and disappear if the app is deleted.

Dashboard → History includes text search, exact-field filters, inclusive calendar
date/month filters, original-amount bounds, report totals, multi-selection, bulk
category changes and reversible deletion. Undo retains up to ten actions within
a 64 MB byte budget for the current session, evicting older actions when needed;
an individually oversized batch is rejected before saving. Restore clears Undo
and rebuilds tabs so stale details/chat evidence do not survive replacement.
The dashboard labels income minus expenses as Net Cash Flow.

Verification: local source review completed; the simulator suite passed 104 tests
with no failures and one intentional private-fixture skip. Tests use disposable
data and cover lossless restore, atomic SQLite failure, pending/intervening edits,
cancellation, Undo chains and retention limits, and exact filtered totals.
Release simulator build passed and the isolated verification app launched.
Accessibility-driven UI checks were blocked by Xcode 27's simulator framework
layout; actual iPhone navigation and Files dialogs still need hands-on verification.
No new model version or automatic migration behavior was introduced in this batch.

Acceptance: disposable backup/restore round-trip preserves every saved field
and attachment; corrupt/future-version archives fail safely; duplicate IDs and
interrupted restores do not partially replace the ledger. Search and totals
agree with existing reports, including currencies and inclusive date boundaries.

### 2. Personal organization and connected evidence

1. Custom categories with SF Symbols, colors, ordering, and archive/unarchive.
   Preserve legacy tag mappings; rename by stable identity, never by rewriting
   an ambiguous label. Update chart, CSV, filters, budgets, and chat together.
2. Tap a chat evidence card to open its matching transactions or full filtered
   results. Show date range, currency, exclusions, and when the answer was
   computed; edited/deleted records must not leave misleading live evidence.
3. Receipt duplicate warnings using reviewed merchant/date/amount/currency and
   an optional image fingerprint. Warn and let the user decide: identical
   purchases can be legitimate. Preserve a clear attachment/provenance link.
4. Optional local merchant-to-category rules based on explicit user choices.
   Preview batch applications; do not silently reclassify old records.

Acceptance: category archival never hides history; stale chat links fail
clearly; rescans warn but never auto-delete or auto-save; rules cannot alter
amounts, currencies, dates, or snapshots.

Personal category management implemented locally after the user's clarification:
Settings → Categories and the transaction form's Manage Categories open native
management screens. Create up to 100 categories, rename them, pick an SF Symbol,
reorder, and archive/unarchive. At least one category stays active. Names are
unique ignoring case and accents and limited to 40 characters. Category colors
remain deferred. There is no deletion or automatic reclassification.

The original tag strings remain stable IDs; new categories use UUID-based IDs.
Category metadata is saved in device preferences and does not change the Core
Data model or automatic migration settings. Existing archived/unknown tags can
be retained when editing a transaction; new assignments must use active categories.
Names and symbols update in history, details, charts and exports. Historical
filters and deterministic chat queries include archived categories. Chat receives
the current category catalogue as untrusted data and validates exact IDs.

Backup format v2 includes names, symbols, order and archived status. V1 remains
readable with its original checksum; restoring v1 resets category settings to
the built-in list. The restore preview lists incoming categories and explicitly
discloses replacement. Recovery archives include the previous catalogue. Editors
reject a save if the same category changed since opening, preserving unrelated
category edits and ordering. No personal ledger or CSV is used by category tests.

Category verification: local review completed and its two findings (stale editor
conflicts and undisclosed category replacement) were resolved. The full isolated
simulator suite passed 112 tests with zero failures and one expected private-fixture
skip. This includes original v1 checksum compatibility, v1/v2 category restoration,
recovery metadata, active/archived editor validation, stable identity and exact
category totals. The Release simulator build passed. The verification app launched successfully in the simulator;
physical iPhone interaction and on-device chat generation remain unverified.

### Insights and chart usability

The native tab bar now has Dashboard, Insights, and Chat. Dashboard summary
cards open the same Insights content in their existing sheet; the old donut-only
screen is removed. Spending and income have selectable bar trends, ranked
category charts, exact category amounts/shares, and navigable transaction rows.
Category charts show the top eight with a complete list below. Chart gestures
are optional: every period and category also has a labelled History link.
Custom names and SF Symbols remain live and archive status never hides history.

Periods include this month, last month, last 7/30 calendar days, this year, and
all time. Comparisons display both actual date ranges and exact amount changes;
percentages are omitted when the prior total is zero. Month/year-to-date use
elapsed comparison windows; a completed month compares full months. Statistics
include the daily average, average transaction, transaction count, largest
transaction, and days without recorded spending. Quiet days are included in the
daily denominator. All time has no prior comparison and begins with the earliest
dated, recognized transaction. Future days and undated records are excluded.

The read-only analytics engine uses the same saved conversions and per-record
Decimal rounding as History. Missing/invalid amounts disable affected totals
and charts, with a path to inspect matching records. Missing prior amounts only
disable comparisons. Unknown transaction types and undated records have explicit
exclusion counts. Bounded calendar buckets keep long histories usable. Dashboard
cards, lists, summary charts and drilldowns use matching calendar boundaries;
mounted views refresh on resume, day rollover and time-zone changes.

This upgrade adds no ledger fields, migrations, dependencies, or automatic
recategorization. It does not add budgets, recurring schedules or forecasting.
Verification: independent local review completed and the calendar-refresh finding
was addressed. The full isolated simulator suite passed 123 tests with no failures
and one expected private-ledger fixture skip. Coverage includes exact totals,
conversion parity, category shares, incomplete conversions, zero baselines,
leap years, DST, rollover boundary parity, and bounded long-history buckets.
The Release simulator build passed; the test-built verification app launched.
Xcode 27's changed SimulatorKit layout blocks accessibility automation, so chart
gestures, VoiceOver/Dynamic Type, and actual iPhone interaction remain unverified.
These changes remain local, uncommitted and unpushed.

### 3. Planning without bookkeeping overhead

1. Calendar-month category budgets in RUB: spent, remaining, and simple progress.
   Start without rollover, daily allowance forecasts, or pay-cycle complexity.
   Missing conversion data must be visible, not omitted from budget totals.
2. Monthly review: comparison with the prior month, category changes, largest
   purchases, and recurring commitments. Compare month-to-date against the
   equivalent elapsed period, not blindly against a complete previous month.
3. Recurring bills/subscriptions with next due date, local reminders, annual
   cost, and a reviewed "Record payment" action. Planned items are not actual
   expenses; recording an occurrence must be idempotent.
4. Extend chat with deterministic budget/month comparison tools. Let the model
   explain results, never invent totals or apply ledger changes.

Acceptance: reminders work without relying on continuous background execution;
month ends, leap years, time zones, missed occurrences, cancellations, and
double-tapped payment actions are covered. Actual and planned totals stay separate.

### 4. Optional convenience and deeper finance

- Quick-entry templates, widgets, Shortcuts, and Action Button entry points.
  Hide financial figures on widgets by default or make visibility explicit.
- Savings goals and annual-bill reserves, initially not pretending to represent
  money in a separate bank account.
- Receipt line items and split categories with reviewed sum reconciliation.
- Linked refunds that reduce the original spending category, rather than
  automatically treating reimbursement as earned income.
- Manual accounts and transfers only if personally useful. Transfers require
  atomic paired entries excluded from spending/income; opening balances,
  cross-currency conversions, fees, and reconciliation need a separate design.
- Optional iCloud synchronization only after restore identity/conflict handling
  is proven; sync is not a substitute for backups.

## Defer

Bank linking, investment tracking, shared households, cloud AI, and autonomous
AI writes. These are not prohibited forever, but are not the next recommended
batch for this personal app. No provider can be assumed to support the user's
banks or countries without a separate compatibility check.

## Architecture boundaries

Keep Core Data as the source of truth. Reuse Decimal conversion and locked
snapshots, and one deterministic query/report boundary for UI, budgets, and AI.
Add independent services for backup validation/restoration, recurrence, and
receipt provenance. Keep domain arithmetic out of generated AI text and views.
Account and transfer semantics must precede any net-worth claims.

Likely affected components: ExpenseCD/model versions; ExpenseView and filter
screens; ExpenseSettingsViewModel and settings UI; SpendingDataStore/chat tools;
ReceiptImportView/AddExpenseViewModel; category configuration and charts; plus
new backup, category, budget, and recurrence modules. Exact file splits belong
to the approved implementation plan, not this product discussion.

## Discussion choices

Recommended first batch: backup/restore + search/history + delete undo.

The consequential next choice is whether Expenso should stay primarily a
spending diary with optional category limits, or evolve into account/balance
management. Prefer the former unless account balances are a daily need.

The initial planning task changed only this document. The subsequent approved
implementation changed app code and added disposable-ledger tests; verification
results are reported separately in the PR. No personal ledger is used by these
new tests. Physical-device performance and real online-provider inference remain
separate verification steps.
