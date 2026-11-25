#!/usr/bin/env bash
# tests/redmine-limit-hint.sh — обёртка bin/redmine: предупреждение о 100-строчном пределе.
#
# Проверяет обе стороны гейта: `issues list` без `--limit` говорит об обрезке (и называет `--limit 0`),
# а вызов с `--limit`, другие команды и `--help` проходят молча. Настоящий CLI не нужен: его роль играет
# заглушка, путь к ней передаётся через REDMINE_REAL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/bin/redmine"
HINT='полный список: --limit 0'

failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub="$tmp/redmine.real"
cat >"$stub" <<'EOF'
#!/usr/bin/env bash
printf 'ЗАГЛУШКА %s\n' "$*"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$stub"

# run_wrapper ARGS... → печатает "rc=<код>" и вывод заглушки, stderr — в $tmp/err
run_wrapper() {
  REDMINE_REAL="$stub" "$WRAPPER" "$@" >"$tmp/out" 2>"$tmp/err"
  printf 'rc=%s\n' "$?"
}

expect_hint() {
  local label="$1"; shift
  local rc
  rc="$(run_wrapper "$@")"
  if [[ "$rc" != "rc=0" ]]; then
    echo "FAIL $label: ожидался код 0, получилось $rc" >&2
    failures=$((failures + 1))
    return
  fi
  if ! grep -qF "$HINT" "$tmp/err"; then
    echo "FAIL $label: нет предупреждения про --limit 0 в stderr:" >&2
    cat "$tmp/err" >&2
    failures=$((failures + 1))
    return
  fi
  if ! grep -q 'ЗАГЛУШКА' "$tmp/out"; then
    echo "FAIL $label: вызов не дошёл до настоящего CLI" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok   $label"
}

expect_silent() {
  local label="$1"; shift
  local rc
  rc="$(run_wrapper "$@")"
  if [[ "$rc" != "rc=0" ]]; then
    echo "FAIL $label: ожидался код 0, получилось $rc" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ -s "$tmp/err" ]]; then
    echo "FAIL $label: лишний вывод в stderr:" >&2
    cat "$tmp/err" >&2
    failures=$((failures + 1))
    return
  fi
  if ! grep -q 'ЗАГЛУШКА' "$tmp/out"; then
    echo "FAIL $label: вызов не дошёл до настоящего CLI" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok   $label"
}

expect_hint 'issues list без --limit' issues list
expect_hint 'issues ls без --limit' issues ls
expect_hint 'issues list -o json без --limit' issues list -o json

expect_silent 'issues list --limit 0' issues list --limit 0
expect_silent 'issues list --limit=50' issues list --limit=50
expect_silent 'issues create' issues create --project demo --subject x
expect_silent 'issues update' issues update 16035 --note x
expect_silent 'help' --help
expect_silent 'issues list --help' issues list --help
expect_silent 'пустой вызов'

# Код возврата настоящего CLI не подменяется: гейт — только строка в stderr.
STUB_EXIT=7 REDMINE_REAL="$stub" "$WRAPPER" issues list >/dev/null 2>&1
rc=$?
if [[ "$rc" -ne 7 ]]; then
  echo "FAIL код возврата CLI: ожидался 7, получилось $rc" >&2
  failures=$((failures + 1))
else
  echo "ok   код возврата CLI"
fi

if (( failures > 0 )); then
  echo "провалов: $failures" >&2
  exit 1
fi
echo "redmine-limit-hint: все проверки прошли"
