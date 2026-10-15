# t9b: `ledger` — multi-currency personal ledger CLI
Add a Python CLI `ledger` to this repo (package `ledger/` runnable as `python3 -m ledger`, stdlib only, tests with unittest).
Commands:
- `add income|expense <amount> <currency> [--date YYYY-MM-DD (default today)] [--note TEXT] [--category TEXT]`
- `list [--month YYYY-MM]`
- `summary --month YYYY-MM`
- `export --month YYYY-MM [--out file.csv]` (stdout if no --out)
- `rate set <CUR> <rate_to_CNY> [--date YYYY-MM-DD (default today)]`, `rate list [<CUR>]`
Global options: `--data PATH` (else env LEDGER_DATA, else ./ledger.json); `--rates PATH` (else rates.json in the same directory as the data file).
Data is JSON; writes are atomic (temp file in same dir + os.replace). Amounts stored as integer minor units.
See tasks/t9b-acceptance.md for the exact contract, formats, limits and exit codes.
Exchange rates are DATED: each entry is converted with the rate effective on the entry's date (most recent rate with date <= entry date).
