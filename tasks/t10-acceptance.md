# t10 public acceptance criteria (extends t9b; all t9b criteria still hold)
## Limits & Input domain (normative)
- L1 Category: 1..200 Unicode code points, matched EXACTLY (case-sensitive, no trimming) against entry categories. Empty -> exit 2.
- L2 Budget amount: CNY, regex `^[0-9]+(\.[0-9]+)?$`, ASCII digits only, <= 2 decimals, > 0, <= 1,000,000 (inclusive). Otherwise exit 2.
- L3 Month: `YYYY-MM` exactly, month 01-12; `--month` is required for all budget commands (missing -> exit 2).
- L4 Files: budgets path = `--budgets PATH` else `<dir of data file>/budgets.json`. Corrupt/invalid-structure budgets.json -> exit 3, file left byte-for-byte unchanged. Missing file = no budgets.
- L5 Exit codes as t9b: 0 success, 2 usage/validation, 3 data problem (incl. missing effective rate for an expense needed by `check`). Errors: one line `error: <message>` on stderr, no traceback.
## Behaviour
- A1 `budget set CAT AMOUNT --month M` stores/replaces the budget for (M, CAT); prints `budget set`; exit 0. Format suggestion: `{"2026-03": {"Food": "1500.00"}}` (amount as decimal string).
- A2 `budget list --month M` prints `CATEGORY<TAB>AMOUNT` (2 decimals) per budget of month M sorted by category (code point order); none -> no output, exit 0.
- A3 `budget check --month M` prints, for each budget of month M (sorted by category): `CATEGORY budget=B spent=S remaining=R status=OK|OVER` with 2 decimals; R = B - S (may be negative, e.g. `-3.50`); status OVER iff S > B. Exit 0.
- A4 spent = sum over EXPENSE entries of month M whose category equals CAT exactly, each converted to CNY per entry with the t9b rule (rate effective on the entry date, HALF-UP to 0.01 per entry, then summed). Income entries never count. Categories without a budget are not shown.
- A5 A budget with no matching expenses shows `spent=0.00`.
- A6 Tests: unittest coverage for every A/L item; `python3 -m unittest discover` passes; ruff (E9,F,B) clean; existing t9b tests still pass unchanged.
