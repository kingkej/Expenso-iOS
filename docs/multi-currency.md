# Multi-currency implementation

## Storage

The V1 model is retained unchanged. V2 adds three optional attributes:
`currencyCode`, `amountText`, and `rateSnapshotData`. With user approval on
October 4, 2026, V2 is selected in both model-version selectors and automatic
lightweight migration is explicitly enabled in the persistence bootstrap.

Existing records without metadata are RUB, independent of the former decorative
currency-symbol preference. The new base preference is `baseCurrencyCode`, default
RUB. Original amounts remain in `amount`; new records also save an exact decimal
string. Rate tables are serialized per transaction and never automatically refreshed.

## Conversion

Dashboard totals, category charts, CSV and chat use the same Decimal conversion
path. Each transaction is converted with its own saved rate and rounded to the
base currency's minor units before totals are summed. Rows and details retain
original amounts/currencies and also show their base conversion.

The date-specific daily USD table comes from the public currency API with a
same-date alternate host. A persistent cache is fresh for 24 hours; expired cache
entries or a different day's quote are not silently substituted. Only the date
and public USD table are requested; ledger data is not sent.

New same-base transactions do not require a quote. Changing base prepares missing
historical snapshots before applying the preference. Any unavailable quote aborts
the base change without altering original amounts. Existing saved rates are used
as-is. A manual table can be extended in the editor by choosing another conversion
currency and entering an explicit rate; existing same-day rates are preserved.
Changing transaction date/currency intentionally requests a new quote. Missing
history can instead be supplied manually. A manual table supports only its saved
pairs, not imaginary cross-rates.

Asynchronous editor/base-setting operations check transaction revisions before
writing. Save failures restore only the fields changed by the operation.

## Verification gates

Static review and PBX/whitespace lint passed. The first approved XcodeBuildMCP
build/test run and the rerun after warning fixes each passed all 27 tests on the
iPhone 17 / iOS 27 simulator, including the isolated V1 SQLite migration fixture.
The built model reports ExpensoV2. A fresh build-and-run succeeded, and the app
also installed/launched on the disposable `Expenso Verification` iPhone 17
simulator; its Dashboard screenshot shows the native toolbar and two-tab bar.
Interactive navigation inspection remains unverified: AXe cannot load the old
SimulatorKit path in Xcode 27, and Device Hub reported display/window failures.
The extra iOS 26.5 compatibility run was interrupted after stalling during
simulator app installation for over nine minutes, before tests started. Xcode
reports this as a canceled/failed run, not a behavioral test failure or pass.
No physical-device installation, real-ledger migration, commit or push was done.

### Owner CSV compatibility check — October 4, 2026

The approved latest Debug build/full suite passed **75 tests, zero failures,
zero skips** on the dedicated Expenso Verification iPhone 17 / iOS 27 simulator.
This includes receipt parsing/evidence tests and a new disposable V1 SQLite
fixture reconstructed from the owner's complete CSV export. Private record
counts, financial totals and the export fingerprint are not published.
Before PR publication, owner-specific test constants were replaced with exact
expectations derived independently from private fixture rows. The follow-up
Debug build/full suite passed: 74 tests passed, zero failures, and the single
private-fixture test skipped as intended because its resource was absent.

Every exported title, amount, type, category, date and note survived V2 migration.
All records stayed RUB with absent new metadata; income, expenses and balance
matched the export exactly. CSV dates lack timezone information, so the fixture reconstructs
them consistently in UTC to verify preservation, not original device timezone.
Original creation/update timestamps and attachments are not in the CSV; the
separate legacy SQLite test verifies those with synthetic values.

The private fixture was temporarily included only in the local test bundle,
never app resources or repository files. Its temporary project registrations,
source JSON, DerivedData copy and dedicated simulator copy were removed after
the passing run. `OwnerLedgerMigrationTests` remains as an opt-in local test and
skips normally when this private resource is absent. Compilation fixes were
needed for the receipt model's generated-type visibility and same-line slicing;
the passing rerun includes both fixes. No installed real ledger was accessed.

The final Release simulator build also passed after removing private resource
registrations. Its bundle identifier remains `com.expenso.Expenso`; its compiled
model selects `ExpensoV2`. No private fixture JSON remains in that Release app.
This is compile/migration evidence, not a signed device build or proof of a real
iPhone upgrade. Existing unrelated deprecation warnings remain.

The shared scheme includes the `ExpensoTests` Swift Testing target. It uses
mocked HTTP responses and isolated memory/SQLite stores. The verification build
overrides `EXPENSO_APP_BUNDLE_ID` with `com.expenso.Expenso.Verification20261004`.
This isolates the host app's normal persistence bootstrap in a disposable app
container without touching an existing simulator ledger. Normal builds retain
the original `com.expenso.Expenso` bundle identifier.

Verification checklist (remaining UI/device checks must not be inferred from
unit/integration test success):

1. Select V2 consistently in `.xccurrentversion` and the Xcode version group.
2. Build through XcodeBuildMCP and fix compilation diagnostics.
3. Exercise an isolated V1 SQLite fixture upgraded to V2: original records,
   attachments, notes, dates and amounts must survive; absent currency is RUB.
4. Verify exact decimal conversion, inverse/cross rates, zero/three-decimal
   currencies, per-transaction rounding, invalid rates, missing pairs, overflow,
   persistent TTL boundary, same-day fallback, cancellation and request dedup.
5. Verify adding/editing BAM with RUB base, preserved locked rates after cache
   expiry, metadata-only edits, date/currency changes, offline manual entry,
   base changes, historical-date failure/recovery, and saved concurrent edits.
6. Verify matching dashboard/chart/CSV/chat totals and original/base display.
   Actual on-device chat inference remains a physical-iPhone check.

Never run migration checks against the owner's real ledger. Use disposable
fixtures and obtain a backup before any later device installation/upgrade.
