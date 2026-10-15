# t12 public acceptance criteria (extends t9b/t10/t11; all earlier criteria still hold)
## Limits & Input domain (normative)
- L1 `--category` may be given 0..10 times; more than 10 -> exit 2.
- L2 Each value must be 1..64 characters after NO trimming, and must not contain control characters (U+0000-U+001F, U+007F); otherwise exit 2.
- L3 Matching is exact and case-sensitive; the literal value `(none)` selects entries with an empty category.
- L4 Errors: one line `error: <message>` on stderr, no traceback; exit codes as before (2 usage/validation, 3 data problem).
## Behaviour
- A1 Without `--category`, `report --year` output is byte-for-byte unchanged.
- A2 With one or more `--category`, only entries of year Y whose category matches any given value are considered; output format is unchanged (category lines in code point order, then `TOTAL ...` computed over the filtered entries only).
- A3 Repeated identical values are treated as one.
- A4 A filter matching no entry prints only `TOTAL income=0.00 expense=0.00 net=0.00` and exits 0.
- A5 Per-entry dated-rate conversion and half-up rounding rules from t11 apply unchanged; a missing rate for a FILTERED-OUT entry does not matter, for a selected entry -> exit 3.
- A6 unittest coverage for every A/L item; `python3 -m unittest discover` passes; ruff (E9,F,B) clean.
