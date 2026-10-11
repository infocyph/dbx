#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -t files < <(find "$ROOT/scripts" "$ROOT/tests" -name '*.sh' -type f | sort)
for file in "${files[@]}"; do
  bash -n "$file"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning "${files[@]}"
fi
python3 - "$ROOT/tests/fixtures/mock-llm/server.py" <<'PY'
import ast, pathlib, sys
ast.parse(pathlib.Path(sys.argv[1]).read_text())
PY
printf 'Static checks passed.\n'
