# t11 public acceptance criteria (extends t9b/t10; all earlier criteria still hold)
## Limits & Input domain (normative)
- L1 Year: `--year` is required; value must match `^[0-9]{4}$` (ASCII digits) and be >= 0001. Otherwise exit 2.
- L2 Categories: grouped by EXACT category string (case-sensitive, no trimming); entries with empty category are grouped under the label `(none)`.
- L3 Exit codes as before: 0 success, 2 usage/validation, 3 data problem (corrupt ledger/rates JSON, or an entry of that year with no effective rate). Errors: one line `error: <message>` on stderr, no traceback.
## Behaviour
- A1 `report --year Y` considers every entry whose date is in calendar year Y (YYYY-01-01..YYYY-12-31).
- A2 Each entry is converted to CNY individually with the rate effective on the entry date (latest rate dated <= entry date; CNY rate 1), rounded HALF-UP to 0.01, then summed.
- A3 Output: one line per category (code point order, `(none)` sorted as that literal string): `CATEGORY income=I expense=E net=N`, then a last line `TOTAL income=I expense=E net=N`; all amounts with 2 decimals, net = income - expense (may be negative, e.g. `-3.50`).
- A4 A year with no entries prints only `TOTAL income=0.00 expense=0.00 net=0.00` and exits 0.
- A5 An entry of year Y without an effective rate -> exit 3, message names the currency and the entry date.
- A6 Tests: unittest coverage for every A/L item; `python3 -m unittest discover` passes; ruff (E9,F,B) clean; existing tests still pass unchanged.
