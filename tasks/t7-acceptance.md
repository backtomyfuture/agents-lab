1. `python3 -m unittest discover -v` passes; `ruff check --select E9,F,B .` is clean.
2. evaluate("2 + 3 * 4") == 14 (int); evaluate("(2 + 3) * 4") == 20; evaluate("7 / 2") == 3.5; evaluate("2 ** 3 ** 2") == 512; evaluate("-2 ** 2") == -4.
3. evaluate("1 / 0") and evaluate("5 % 0") raise ExpressionError with message "division by zero".
4. evaluate("2 +") and evaluate("(1 + 2") raise ExpressionError whose message contains the character position.
5. No use of eval, exec, compile or ast anywhere in expr_eval.py.
6. CLI behaves as described (exit codes 0/1, stderr "error: ..."), including stdin mode.
