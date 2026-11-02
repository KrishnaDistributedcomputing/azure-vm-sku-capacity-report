#!/usr/bin/env bash
# Offline tests for azure-vm-sku-report.sh using the mock Azure CLI in this folder.
# Usage: test/run-tests.sh      (needs bash, jq; no Azure login)
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(mktemp -d); OUT=$(mktemp -d); trap 'rm -rf "$BIN" "$OUT"' EXIT
ln -s "$PWD/test/mock-az" "$BIN/az"; export PATH="$BIN:$PATH"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }; ko(){ echo "FAIL: $1"; fail=$((fail+1)); }
data(){ sed -n '/^const D =$/,/^;/p' "$1" | sed '1d;$d'; }

# 1. Normal run, read-only calls only, owner-only file permissions
export MOCK_LOG="$OUT/calls.log"
./azure-vm-sku-report.sh -l "eastus westus" -s 00000000-1111-2222-3333-444444444444 -o "$OUT/n.html" 2>/dev/null
[[ $(data "$OUT/n.html" | jq '.skus | length') == 13 ]] && ok "13 SKUs in report" || ko "SKU count"
[[ $(data "$OUT/n.html" | jq '[.skus[] | select(.sev=="fail")] | length') == 6 ]] && ok "6 predicted failures" || ko "fail count"
[[ $(stat -c %a "$OUT/n.html") == 600 ]] && ok "report is 0600" || ko "report permissions"
if grep -qvE '^(account (show|list-locations)|vm list-(skus|usage)|capacity reservation (group )?list) ' "$MOCK_LOG"; then ko "non read-only az call: $(grep -vE '^(account (show|list-locations)|vm list-(skus|usage)|capacity reservation (group )?list) ' "$MOCK_LOG" | head -1)"; else ok "only read-only az commands"; fi
grep -q 'account set' "$MOCK_LOG" && ko "az account set was called" || ok "default subscription not changed"
unset MOCK_LOG

# 2. Malicious data: nothing from Azure may appear unescaped in the HTML
MOCK_EVIL=1 ./azure-vm-sku-report.sh -l eastus -f '<script>|X|cmd|Y' -o "$OUT/e.html" 2>/dev/null
[[ $(grep -o '<script' "$OUT/e.html" | wc -l) == 1 && $(grep -o '</script' "$OUT/e.html" | wc -l) == 1 ]] && ok "single <script> block (no breakout)" || ko "script breakout"
grep -qE '<img|<svg|<b>x' "$OUT/e.html" && ko "raw HTML payload in file" || ok "payloads escaped in embedded JSON"
grep -q "Content-Security-Policy\" content=\"default-src 'none'; script-src 'sha256-" "$OUT/e.html" && ok "CSP with script hash" || ko "CSP missing"

# 3. Bad input is rejected before any Azure call
for args in "-l eastus;id" "-l *" "-f ([" "-s --debug"; do
  # shellcheck disable=SC2086
  if ./azure-vm-sku-report.sh $args -o "$OUT/x.html" >/dev/null 2>&1; then ko "accepted bad input: $args"; else ok "rejected: $args"; fi
done

# 4. Redaction
./azure-vm-sku-report.sh -l eastus -r -o "$OUT/r.html" 2>/dev/null
grep -q '444444444444' "$OUT/r.html" && ko "subscription ID not redacted" || ok "subscription ID redacted"

echo "$pass passed, $fail failed"; (( fail == 0 ))
