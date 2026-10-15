# Arithmetic expression evaluator with CLI
Add a new module `expr_eval.py` to this repo that safely parses and evaluates arithmetic expressions, plus a CLI.
- Supports: integers and decimals, + - * / %, ** (right-associative, binds tighter than unary minus: -2**2 == -4), unary + and -, parentheses, whitespace.
- Must NOT use eval/exec/compile or the ast module; implement a tokenizer + recursive-descent (or precedence-climbing) parser.
- Public API: `evaluate(expression: str) -> float | int` (return int when the result is integral and all operands were integers and no '/' was used; else float), and `ExpressionError(Exception)` for any syntax error (with a message that includes the 0-based character position), division/modulo by zero raises ExpressionError("division by zero").
- CLI: `python3 expr_eval.py "<expression>"` prints the result and exits 0; on ExpressionError prints `error: <message>` to stderr and exits 1; with no argument reads one expression per line from stdin and prints one result (or error line) per line, exit code 1 if any line failed.
- Keep calc.py unchanged.
