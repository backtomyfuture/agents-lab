# t9 public acceptance criteria
## Limits & Input domain (normative)
- L1 Currencies: whitelist CNY, USD, EUR, JPY, HKD. Input case-insensitive (`usd` ok), stored/printed uppercase. Anything else -> exit 2.
- L2 Minor units: JPY 0 decimals; CNY/USD/EUR/HKD 2 decimals. Stored as integer minor units.
- L3 Amount: regex `^[0-9]+(\.[0-9]+)?$` with ASCII digits only; number of decimals <= currency decimals; value > 0; value <= 1,000,000 major units (inclusive). Otherwise exit 2.
- L4 Rate (`rate set`): ASCII decimal matching `^[0-9]+(\.[0-9]+)?$`, at most 6 decimals, 0 < rate <= 10000. `rate set CNY ...` -> exit 2 (CNY rate fixed at 1). Otherwise exit 2.
- L5 Date: `YYYY-MM-DD` exactly (zero-padded) and a real calendar date. Month: `YYYY-MM` exactly, month 01-12. Otherwise exit 2.
- L6 Note/category: at most 200 characters each (Unicode code points); UTF-8. Longer -> exit 2. Default empty string.
- L7 Exit codes: 0 success; 2 usage/validation error; 3 data-file problem (unreadable/corrupt/invalid-structure JSON in ledger or rates file, write failure, or missing rate for a currency needed by summary). Errors print one line `error: <message>` to stderr; never a Python traceback.
## Behaviour
- A1 `add` appends an entry {date, type, amount_minor, currency, category, note} to the data file and prints `added`; exit 0. Missing data file = empty ledger (created on first add).
- A2 Data/rates path resolution as in task.md (`--data` > `LEDGER_DATA` > `./ledger.json`; `--rates` > `<dir of data file>/rates.json`).
- A3 Writes are atomic (temp file in same directory + os.replace). If the ledger or rates file is corrupt JSON, any command exits 3 with a clear message and the file is left byte-for-byte unchanged.
- A4 `list [--month]` prints one line per entry, sorted by date then insertion order: `DATE<TAB>TYPE<TAB>AMOUNT<TAB>CUR<TAB>CATEGORY<TAB>NOTE`, AMOUNT formatted with the currency's decimals (e.g. `12.50`, `300`). No entries -> no output, exit 0.
- A5 `summary --month M` prints, for each currency used in that month (alphabetical): `CUR income=X expense=Y net=Z` (currency decimals; net may be negative, e.g. `-3.00`), then a final line `CNY-total income=X expense=Y net=Z` (2 decimals).
- A6 CNY conversion: for each currency, convert its income total and expense total separately: total_minor * rate -> CNY, rounded HALF-UP to 0.01 CNY (use Decimal); CNY-total income/expense are sums of those rounded values; net = income - expense. CNY rate is 1. A currency used in the month with no rate -> exit 3, message names the currency.
- A7 `export --month M [--out F]` writes CSV (csv module, UTF-8, header `date,type,amount,currency,category,note`, same rows/order/formatting as list) to F or stdout. Fields containing commas/quotes/newlines must be correctly quoted.
- A8 `rate set CUR R` stores the rate (as a decimal string) in the rates file; `rate list` prints `CUR<TAB>RATE` lines sorted by currency, including `CNY<TAB>1`.
- A9 Tests: unittest suite covering every A/L item; `python3 -m unittest discover` passes; ruff (E9,F,B) clean; stdlib only; existing files keep working.
