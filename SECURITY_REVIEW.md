# Security review: `azure-vm-sku-report.sh`

**Scope:** `azure-vm-sku-report.sh` (Bash + Azure CLI + jq) and the HTML report it generates.
**Reviewed:** 2026-11-02, script version 1.2.0 (see the README changelog).
**Method:** manual code review, `shellcheck` 0.11 (no findings at the `info` level), and offline tests with a mock Azure CLI
(`test/run-tests.sh`). The tests include a malicious data set: SKU names, family names, zone names, restriction reasons and
a subscription name that contain `</script>`, `<img onerror>`, `<svg onload>`, quotes, `<!--`, shell metacharacters and
CSV formula prefixes (`=`, `+`, `-`, `@`).

Severity scale: **High**: realistic compromise of the user or data. **Medium**: exploitable under plausible conditions, or a
real data-exposure risk. **Low**: defence in depth or hygiene. **Info**: no change needed.

## Summary

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | `az account set` changed the user's default subscription | Medium | Fixed |
| 2 | Report embeds JSON in `<script>`, so a narrow escape could allow breakout / XSS | Medium | Fixed (hardened) |
| 3 | No Content-Security-Policy on the report | Low | Fixed |
| 4 | CSV export vulnerable to formula (CSV) injection | Medium | Fixed |
| 5 | Report and temp files readable by other users (default umask) | Medium | Fixed |
| 6 | Subscription ID and name are in the report, with no marking or redaction option | Low | Fixed (banner + `-r`) |
| 7 | Unquoted region list and `$(...)` loop were subject to globbing and word splitting | Low | Fixed |
| 8 | No validation of `-l`, `-s`, `-f`, `-o` inputs | Low | Fixed |
| 9 | Copy-paste commands in the help tab built from Azure data | Low | Fixed |
| 10 | Temp-dir cleanup on Ctrl+C / SIGTERM | Low | Fixed |
| 11 | `-f` regex handed to jq: injection / ReDoS | Info | Accepted |
| 12 | Writes or changes to Azure | Info | None found |
| 13 | External resources loaded by the page | Info | None |
| 14 | `set -euo pipefail` robustness | Info | Reviewed, minor fixes |
| 15 | Least-privilege RBAC | Info | Documented (Reader) |

## Findings

### 1. `az account set` changed the user's default subscription (Medium, fixed)
**Description:** With `-s`, the script ran `az account set --subscription <id>`. That permanently switches the CLI's default
subscription for the user, and for every later script and shell session that shares `~/.azure`. Someone who then runs
`az vm create` or `az group delete` without thinking could act on the wrong subscription. Strictly speaking this is a
local state change, not an Azure change, but it's a real safety risk.
**Fix:** The script no longer calls `az account set`. The subscription goes into a `SUBARGS=(--subscription "$SUBSCRIPTION")`
array that is passed to every `az account show`, `az vm list-skus`, `az vm list-usage` and `az capacity reservation ...`
call. `test/run-tests.sh` fails if `account set` is ever called. The help tab's checklist also uses `--subscription` instead
of `az account set`.

### 2. JSON-in-`<script>` breakout and XSS (Medium, fixed / hardened)
**Description:** All report data (SKU names, families, zones, restriction reasons, quota names, az error text, the
subscription name, the `-f` filter and region names) is embedded as `const D = {...}` inside an inline `<script>`. A value
containing `</script>` would end the script element and inject markup. The earlier version replaced `</` with `<\/` and
`<!--` with `<\u0021--`. That blocked the known vectors, but it was a denylist.
**Fix:** After `jq -c` builds the JSON, the script replaces every `<`, `>` and `&` with the JSON escapes `\u003c`, `\u003e`,
`\u0026`. These characters can only appear inside JSON strings, so the result is still valid JSON and JavaScript, and the
script block can never contain `</script`, `<!--` or `<script`. When the page renders, every value goes through `esc()`,
which encodes `& < > " '`, before it is put into `innerHTML`. Single quotes are now covered too. The header line uses
`textContent`. Class names and anchor targets come only from a fixed internal set (`sev`, `cat`) or are escaped. The help
commands are set with `textContent`.
**Verified:** With the malicious mock data the file has exactly one `<script>` and one `</script>`. The rendered DOM has no
`<img>`, `<svg>` or injected attributes, and the payloads show up as literal text.

### 3. No Content-Security-Policy (Low, fixed)
**Description:** Without a CSP, any future escaping bug could load remote scripts or send data out.
**Fix:** A `<meta http-equiv="Content-Security-Policy">` is added:
`default-src 'none'; script-src 'sha256-<hash of the one inline script>'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'`.
The hash is computed at build time with `openssl`. If `openssl` is missing, the policy falls back to `'unsafe-inline'`
(Cloud Shell has openssl). This blocks every network fetch, injected inline scripts and event-handler attributes.
`<meta name="referrer" content="no-referrer">` and `robots noindex` are also set.
**Accepted residual:** `style-src 'unsafe-inline'` is kept because the page uses one `<style>` block and inline width styles
for the quota bars. Style injection can't run code, and there is no network access to exfiltrate to.

### 4. CSV / formula injection in "Download CSV" (Medium, fixed)
**Description:** Cells were quoted, but a value starting with `=`, `+`, `-` or `@` (for example a crafted name such as
`=HYPERLINK(...)`) would run as a formula when the CSV is opened in Excel or Sheets.
**Fix:** Any cell that starts with `=`, `+`, `-`, `@`, tab or CR gets a leading `'`, unless it is a plain number such as `-4`
(negative free quota). Quotes are doubled, and rows end with CRLF.
**Verified:** `=HYPERLINK(...)` is exported as `'=HYPERLINK(...)`, `+cmd|...` as `'+cmd|...`, `@SUM(1+1)` as `'@SUM(1+1)`.

### 5. Report and temp file permissions (Medium, fixed)
**Description:** The report holds subscription details and quota. It was written with the default umask (usually 0644,
world-readable on shared hosts). The temp directory from `mktemp -d` was already 0700.
**Fix:** `umask 077` at startup. The report is built in the private temp dir, moved into place, and then `chmod 600`. The
temp dir is named `vmsku.XXXXXXXX` under `$TMPDIR` and removed on exit. A test checks for mode 600.

### 6. Sensitive data in the report (Low, fixed)
**Description:** The subscription ID, subscription name, regions, quota usage and capacity reservation names (including
resource group names) are included. That's needed for the report to be useful, but it's internal information.
**Fix:** A visible "CONFIDENTIAL" banner in the header. A new `-r` option masks the subscription ID (keeps the last 4 hex
characters) and replaces the name with "(redacted)", so a report can be shared with Microsoft or a partner. The README says
not to publish or commit real reports, and `.gitignore` ignores `*.html` except `docs/`.
**Accepted:** Capacity reservation group and resource group names aren't redacted by `-r`. Use `-x` to leave them out.
No credentials or tokens are ever written to the report.

### 7. Globbing and word splitting of region and reservation lists (Low, fixed)
**Description:** `for LOC in $LOCATIONS` and `for RG_ID in $(az ...)` were unquoted. A region argument such as `*` would
expand to file names in the current directory, and odd whitespace would split values.
**Fix:** Regions are read into an array with `read -r -a` (no globbing), and capacity reservation IDs are read line by line
with `while IFS= read -r`. Every expansion is quoted.

### 8. Input validation (Low, fixed)
**Description:** CLI arguments went to `az` and `jq` without checks. They were always passed as separate arguments, never
through `eval` or string interpolation into code, so there was no command injection. But bad values gave confusing
failures part-way through the run.
**Fix:**
- `-l`: each region must match `^[a-z0-9]+$`.
- `-s`: may not start with `-`, so it can't be read as an az option such as `--debug`.
- `-f`: compiled once with jq first, so an invalid regex fails with a clear message.
- `-o`: must not be a directory.

Everything is checked before the first `az` data call.

### 9. Copy-paste commands in the help tab (Low, fixed)
**Description:** The help tab pre-fills commands such as `az vm list-skus --size <SKU>` with a region, SKU, family and
subscription from the report. A crafted SKU name like `Standard_Y; rm -rf ~` would turn into a dangerous command if a user
copied it into a shell.
**Fix:** Only values matching `^[A-Za-z0-9_.-]{1,80}$` are filled in. Anything else becomes a placeholder such as
`<vm-size>`. When `-r` is used, the subscription is always `<subscription-id>`.

### 10. Cleanup on interrupt (Low, fixed)
`trap 'rm -rf "$TMP"' EXIT` plus `trap 'exit 130' INT` / `trap 'exit 143' TERM`, so the EXIT trap also runs on Ctrl+C.

### 11. `-f` regex passed to jq (Info, accepted)
The filter is passed with `jq --arg`, so it is data, not jq code. There's no injection. A pathological regex can make
matching slow (ReDoS), but the input comes from the person running the script on their own machine, so that's accepted.

### 12. Changes to Azure state (Info, none)
Every Azure call is read-only: `az account show`, `az account list-locations`, `az vm list-skus`, `az vm list-usage`,
`az capacity reservation group list` and `az capacity reservation list`. The mock logs every call, and the tests fail on
anything else. The *help text* shows write commands (`az quota update`, `az capacity reservation create`, `az vm create`)
for the user to run on purpose. The script never runs them.

### 13. External resources (Info, none)
The page loads no scripts, styles, fonts, images or analytics from outside. It works offline, and the CSP enforces that.
The only external URLs are `<a target="_blank" rel="noopener">` links to learn.microsoft.com, opened only when clicked.

### 14. `set -euo pipefail` robustness (Info, reviewed)
- Per-region `az` failures are caught (`|| echo "[]"`), so one bad region doesn't stop the run, and the region is shown in
  the report's "Regions with no data" banner.
- A short-circuit `[[ ]] && echo` inside the loop is now an `if`.
- An empty `SUBARGS` array is safe under `set -u` in bash 4.4+ (Cloud Shell has bash 5).
- `az account show` failing for a bad `-s` stops with a clear error.

### 15. Least privilege (Info, documented)
The built-in **Reader** role at subscription scope is enough. A custom role needs only:
`Microsoft.Resources/subscriptions/read`, `Microsoft.Resources/subscriptions/locations/read`, `Microsoft.Compute/skus/read`,
`Microsoft.Compute/locations/usages/read`, `Microsoft.Compute/capacityReservationGroups/read` and
`Microsoft.Compute/capacityReservationGroups/capacityReservations/read`. See README > Required permissions.

## Not covered / residual risk
- The report trusts Azure CLI output. A compromised `az` binary or a man-in-the-middle on Azure APIs is out of scope.
- A `-o` path that is a symlink is followed (normal shell behaviour). Don't write reports into directories that other users
  can write to.
- The CSP hash fallback (`'unsafe-inline'`) applies only when `openssl` isn't installed.
- No downloads were tested in a real browser under the CSP. Headless Chrome showed the CSV is built correctly, and blob
  downloads aren't governed by `default-src`.
