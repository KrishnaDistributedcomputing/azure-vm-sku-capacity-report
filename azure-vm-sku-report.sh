#!/usr/bin/env bash
# azure-vm-sku-report.sh
# Version: 1.3.0
# One script: finds which Azure VM SKUs a subscription can deploy, checks vCPU quota,
# predicts which SKUs will fail (and with which Azure error code), lists capacity
# reservations, and writes a self-contained, searchable HTML report with a help tab.
#
# Requirements: Azure CLI (az) logged in (`az login`) and jq. Works in Azure Cloud Shell.
# Usage:
#   ./azure-vm-sku-report.sh -l eastus
#   ./azure-vm-sku-report.sh -l "eastus westeurope" -s <subscription-id> -f "Standard_D" -o report.html
#   Options:
#     -l  regions (space-separated). Omit to scan every physical region (slow, large report).
#     -s  subscription id or name (default: current az account)
#     -f  SKU name filter, regex, case-insensitive (e.g. "Standard_D", "NC|ND"). Without an "_" in the
#         filter it is matched against the size name without the "Standard_" prefix, so "ND" does not match "Standard".
#     -o  output HTML file (default: azure-vm-sku-report.html)
#     -x  skip the capacity reservation lookup
#     -r  redact: mask the subscription ID and name in the report (for sharing outside your team)
#
# Read-only: the script only runs list/show commands and never changes Azure resources or your
# default az subscription (-s is passed per command with --subscription). The Reader role is enough.
# The report contains subscription details and is written with owner-only permissions (0600).
#
# Predictions are based on SKU restrictions and vCPU quota only. Azure does not publish free
# hardware capacity, so a SKU predicted to deploy can still fail with AllocationFailed.

set -euo pipefail
umask 077            # temp files and the report are readable by the current user only

LOCATIONS=""; SUBSCRIPTION=""; FILTER=""; OUTFILE="azure-vm-sku-report.html"; SHOW_CRG=true; REDACT=false
die(){ echo "Error: $*" >&2; exit 1; }
while getopts "l:s:f:o:xrh" opt; do
  case $opt in
    l) LOCATIONS="$OPTARG" ;; s) SUBSCRIPTION="$OPTARG" ;; f) FILTER="$OPTARG" ;;
    o) OUTFILE="$OPTARG" ;; x) SHOW_CRG=false ;; r) REDACT=true ;; h|*) sed -n '2,27p' "$0"; exit 0 ;;
  esac
done

command -v az >/dev/null || { echo "Azure CLI (az) is not installed." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is not installed." >&2; exit 1; }
az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"

# --- Validate inputs before calling Azure ---
[[ -n "$OUTFILE" && ! -d "$OUTFILE" ]] || die "-o must be a file path, not a directory."
if [[ -n "$FILTER" ]]; then
  jq -n --arg f "$FILTER" '"x" | test($f; "i")' >/dev/null 2>&1 || die "-f is not a valid regular expression: $FILTER"
fi
# Pass the subscription to every az call instead of changing the user's default (az account set)
SUBARGS=()
if [[ -n "$SUBSCRIPTION" ]]; then
  [[ "$SUBSCRIPTION" != -* ]] || die "-s must be a subscription ID or name."
  SUBARGS=(--subscription "$SUBSCRIPTION")
fi

SUB_NAME=$(az account show "${SUBARGS[@]}" --query name -o tsv) || die "Cannot read subscription '$SUBSCRIPTION'. Check the ID/name and your access."
SUB_ID=$(az account show "${SUBARGS[@]}" --query id -o tsv)
echo "Subscription: $SUB_NAME ($SUB_ID)" >&2

if [[ -z "$LOCATIONS" ]]; then
  # list-locations has no --subscription option; region names are the same across subscriptions
  LOCATIONS=$(az account list-locations --query "[?metadata.regionType=='Physical'].name" -o tsv)
  echo "No -l given: scanning all $(echo "$LOCATIONS" | wc -w) physical regions. This is slow and the report can be large;" \
       "use -l and/or -f to narrow it." >&2
fi
# Split into an array without glob expansion, and accept only valid region names (e.g. eastus, westus3)
read -r -a LOC_LIST <<< "$(tr '\n\t,' '   ' <<< "$LOCATIONS")"
(( ${#LOC_LIST[@]} > 0 )) || die "No regions to scan."
for LOC in "${LOC_LIST[@]}"; do
  [[ "$LOC" =~ ^[a-z0-9]+$ ]] || die "Invalid region name '$LOC'. Use names like eastus or westeurope (az account list-locations -o table)."
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/vmsku.XXXXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT; trap 'exit 143' TERM
echo "[]" > "$TMP/skus.json"; echo "[]" > "$TMP/quota.json"; echo "[]" > "$TMP/crg.json"; echo "[]" > "$TMP/regions.json"

for LOC in "${LOC_LIST[@]}"; do
  echo "Querying $LOC ..." >&2
  ERR=""
  if ! az vm list-skus "${SUBARGS[@]}" --location "$LOC" --resource-type virtualMachines --all -o json > "$TMP/raw.json" 2> "$TMP/err.txt"; then
    ERR=$(head -c 300 "$TMP/err.txt" | tr '\n' ' '); echo "[]" > "$TMP/raw.json"
    echo "  warning: az vm list-skus failed for $LOC: $ERR" >&2
  fi
  jq -e 'type == "array"' "$TMP/raw.json" >/dev/null 2>&1 || echo "[]" > "$TMP/raw.json"
  az vm list-usage "${SUBARGS[@]}" --location "$LOC" -o json > "$TMP/usage.raw.json" 2>/dev/null || echo "[]" > "$TMP/usage.raw.json"
  # Newer Azure CLI versions return currentValue/limit as strings; convert them to numbers
  jq 'map(.currentValue = ((.currentValue // 0) | tonumber? // 0) | .limit = ((.limit // 0) | tonumber? // 0))' \
    "$TMP/usage.raw.json" > "$TMP/usage.json" 2>/dev/null || echo "[]" > "$TMP/usage.json"

  # Quota rows for the report. Keep limit-0 rows: a family quota of 0 is the reason a SKU can't deploy.
  jq --arg loc "$LOC" '[.[] | {region:$loc, name:(.localName // .name.localizedValue // .name.value),
      key:.name.value, used:.currentValue, limit:.limit, free:(.limit - .currentValue)}]' "$TMP/usage.json" > "$TMP/q.json"
  jq -s 'add' "$TMP/quota.json" "$TMP/q.json" > "$TMP/q2.json" && mv "$TMP/q2.json" "$TMP/quota.json"

  jq --arg loc "$LOC" --arg filter "$FILTER" --slurpfile usage "$TMP/usage.json" '
    def num: (tonumber? // 0);
    def cap($n): ((.capabilities // []) | map(select(.name == $n)) | .[0].value) // null;
    def quota($n): ($usage[0] | map(select(((.name.value // "") | ascii_downcase) == ($n | ascii_downcase))) | .[0]);
    def zl: if length == 1 then "zone " + .[0] else "zones " + join(", ") end;
    ($usage[0] | length > 0) as $haveUsage
    | (quota("cores")) as $reg
    | (if $reg then ($reg.limit - $reg.currentValue) else null end) as $regFree
    # Zones the region offers = union of zones of every SKU in it
    | ([.[] | (.locationInfo // [])[] | (.zones // [])[]] | unique | sort) as $regionZones
    | [ .[]
      | select(($filter == "") or ((if ($filter | test("_")) then .name else (.name | sub("^(Standard|Basic)_"; "")) end) | test($filter; "i")))
      | .name as $n
      | (.restrictions // []) as $r
      | ($r | map(select(.type == "Location"))) as $locR
      | ($r | map(select(.type == "Zone")) | map(.restrictionInfo.zones // []) | add // [] | unique | sort) as $zoneR
      | ((.locationInfo // []) | map(.zones // []) | add // [] | unique | sort) as $zones
      | ($zones - $zoneR) as $okZones
      | (if ($locR | length) > 0 then "NotAvailable" elif ($zoneR | length) > 0 then "PartiallyAvailable" else "Available" end) as $status
      | (quota(.family // "")) as $fam
      | ((cap("vCPUs") // "0") | num) as $cpu
      | ((cap("MemoryGB") // "0") | num) as $mem
      | ((cap("GPUs") // "0") | num) as $gpu
      | (if $fam then ($fam.limit - $fam.currentValue) else null end) as $famFree
      | ([$famFree, $regFree] | map(select(. != null)) | min) as $free
      | (if ($locR | length) > 0 then null
         elif $cpu > 0 and $free != null then ([(($free / $cpu) | floor), 0] | max) else null end) as $maxVMs
      # Allocation-risk heuristics (Azure publishes no capacity data; these are rules of thumb)
      | ([ (if $gpu > 0 or ($n | test("^Standard_N"; "i")) then "GPU size" else empty end),
           (if $n | test("^Standard_H"; "i") then "HPC size" else empty end),
           (if $n | test("^Standard_M"; "i") then "M-series (large memory)" else empty end),
           (if $n | test("^(Basic_A[0-9]+|Standard_A([0-9]|1[01])|Standard_DS?([1-4]|1[1-4])|Standard_DS?15_v2|Standard_GS?[1-5](-[0-9]+)?)$"; "i")
              then "legacy size on older hardware" else empty end) ]) as $riskHigh
      | ([ (if $cpu >= 64 or $mem >= 512 then "very large size" else empty end),
           (if ($regionZones | length) > 1 and ($zones | length) == 1 then "offered in only one zone" else empty end) ]) as $riskMed
      # Every issue found, highest priority first. The first one is the predicted outcome.
      | ([
          (if ($locR | length) > 0 then
             ($locR | map(.reasonCode) | unique | join(", ")) as $rc
             | {p:1, sev:"fail", cat:"restricted", code:"SkuNotAvailable",
                text:("Will fail: SKU restricted for this subscription in this region (" + $rc + ")")} else empty end),
          (if $fam != null and $fam.limit == 0 and $cpu > 0 then
             {p:2, sev:"fail", cat:"quota0", code:"OperationNotAllowed / QuotaExceeded",
              text:"Will fail: family vCPU quota is 0 (request an increase)"}
           elif $fam != null and $cpu > 0 and $famFree < $cpu then
             {p:3, sev:"fail", cat:"famquota", code:"OperationNotAllowed / QuotaExceeded",
              text:("Will fail: family quota exceeded (needs " + ($cpu|tostring) + " vCPUs, " + ([$famFree,0]|max|tostring) + " free)")}
           else empty end),
          (if $reg != null and $cpu > 0 and $regFree < $cpu then
             {p:4, sev:"fail", cat:"regquota", code:"OperationNotAllowed / QuotaExceeded",
              text:("Will fail: regional vCPU quota exceeded (needs " + ($cpu|tostring) + ", " + ([$regFree,0]|max|tostring) + " free)")}
           else empty end),
          (if ($zoneR | length) > 0 and ($okZones | length) == 0 then
             {p:5, sev:"warn", cat:"zonal", code:"SkuNotAvailable",
              text:("Zonal deploy fails in all zones (" + ($zoneR|join(", ")) + "); a non-zonal deploy may still work")}
           elif ($zoneR | length) > 0 then
             {p:5, sev:"warn", cat:"zonal", code:"SkuNotAvailable",
              text:("Zonal deploy fails in " + ($zoneR|zl) + "; use " + ($okZones|zl))}
           else empty end),
          (if ($regionZones | length) > 1 and ($zones | length) > 0 and ($zones | length) < ($regionZones | length) then
             {p:9, sev:"info", cat:"zonepinned", code:"",
              text:("Only offered in " + ($zones|zl) + "; pinning another zone fails (SkuNotAvailable)")}
           elif ($regionZones | length) > 0 and ($zones | length) == 0 then
             {p:9, sev:"info", cat:"nozones", code:"",
              text:"No availability-zone support here; deploy without a zone (pinning a zone fails: SkuNotAvailable)"}
           else empty end),
          (if ($haveUsage | not) then
             {p:6, sev:"warn", cat:"quotaunknown", code:"", text:"Quota not checked: az vm list-usage returned nothing"}
           elif $fam == null and $cpu > 0 then
             {p:6, sev:"warn", cat:"quotaunknown", code:"",
              text:("Quota unknown: family " + (.family // "?") + " not in usage list")}
           else empty end),
          (if ($riskHigh | length) > 0 then
             {p:7, sev:"risk", cat:"alloc", code:"AllocationFailed / ZonalAllocationFailed",
              text:("Allocation risk: high (" + ($riskHigh + $riskMed | join(", ")) + ")")}
           elif ($riskMed | length) > 0 then
             {p:7, sev:"risk", cat:"alloc", code:"AllocationFailed / ZonalAllocationFailed",
              text:("Allocation risk: medium (" + ($riskMed | join(", ")) + ")")}
           else empty end),
          (if $maxVMs != null and $maxVMs >= 1 and $maxVMs <= 2 then
             {p:8, sev:"warn", cat:"quotatight", code:"OperationNotAllowed / QuotaExceeded",
              text:("Quota tight: only " + ($maxVMs|tostring) + " VM(s) of this size fit")}
           else empty end)
        ] | sort_by(.p)) as $issues
      | ($issues | map(select(.sev == "fail")) | length > 0) as $fails
      | ($issues[0] // {sev:"ok", cat:"ok", code:"", text:"Will deploy"}) as $top
      # info-only (zone layout) issues do not stop a deployment: say so in the outcome text
      | (if $top.sev == "info" then $top + {text:("Will deploy. " + $top.text)} else $top end) as $pred
      | ([ ((cap("HyperVGenerations") // "") as $hv
           | (if $hv == "V2" then "Gen2 images only" elif $hv == "V1" then "Gen1 images only" else empty end)),
           (if (cap("AcceleratedNetworkingEnabled") // "") == "False" then "No accelerated networking (disable it on the NIC)" else empty end)
         ]) as $extra
      | { region:$loc, sku:$n, family:(.family // ""), vcpus:$cpu, memGB:$mem,
          maxDisks:((cap("MaxDataDiskCount") // "")), gpus:(if $gpu > 0 then $gpu else "" end),
          zones:($zones | join(" ")), restrictedZones:($zoneR | join(" ")),
          status:$status, reason:($r | map(.reasonCode) | unique | join(" ")),
          famUsed:$fam.currentValue, famLimit:$fam.limit, famFree:$famFree, regFree:$regFree, maxVMs:$maxVMs,
          canDeploy:(if ($locR | length) > 0 then "No (restricted)" elif $fails then "No (quota)"
                     elif $maxVMs == null or ($fam == null and $cpu > 0) then "Unknown" else "Yes" end),
          outcome:$pred.text, sev:$pred.sev, cat:$pred.cat, code:$pred.code,
          notes:(($issues[1:] | map((.text | sub("^Will fail: "; "")) + (if .code != "" then " [" + .code + "]" else "" end))) + $extra | join("; ")) } ]' \
    "$TMP/raw.json" > "$TMP/s.json"
  jq -s 'add' "$TMP/skus.json" "$TMP/s.json" > "$TMP/s2.json" && mv "$TMP/s2.json" "$TMP/skus.json"
  N=$(jq length "$TMP/s.json")
  if [[ "$N" == "0" && -z "$ERR" ]]; then
    echo "  note: no VM SKUs returned for $LOC (region may not be enabled for this subscription or the filter matched nothing)" >&2
  fi
  jq --arg loc "$LOC" --arg err "$ERR" --argjson n "$N" '. + [{region:$loc, skus:$n, error:$err}]' "$TMP/regions.json" > "$TMP/r2.json" \
    && mv "$TMP/r2.json" "$TMP/regions.json"
done

if $SHOW_CRG; then
  echo "Checking capacity reservations ..." >&2
  az capacity reservation group list "${SUBARGS[@]}" --query "[].id" -o tsv 2>/dev/null > "$TMP/crg-ids.txt" || : > "$TMP/crg-ids.txt"
  while IFS= read -r RG_ID; do
    [[ -n "$RG_ID" ]] || continue
    RG=$(cut -d/ -f5 <<< "$RG_ID"); NAME=${RG_ID##*/}
    az capacity reservation list "${SUBARGS[@]}" -g "$RG" --capacity-reservation-group "$NAME" -o json 2>/dev/null \
      | jq --arg g "$NAME" --arg rg "$RG" '[.[] | {group:$g, rg:$rg, name:.name, region:.location, sku:.sku.name, reserved:.sku.capacity, zones:((.zones // []) | join(" "))}]' > "$TMP/c.json" \
      || echo "[]" > "$TMP/c.json"
    jq -s 'add' "$TMP/crg.json" "$TMP/c.json" > "$TMP/c2.json" && mv "$TMP/c2.json" "$TMP/crg.json"
  done < "$TMP/crg-ids.txt"
fi

TOTAL=$(jq length "$TMP/skus.json")
if (( TOTAL > 20000 )); then
  echo "Warning: $TOTAL SKU rows. The report will be large; the table shows the first 2000 matching rows at a time (CSV export has all)." >&2
fi

if $REDACT; then
  SUB_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxx${SUB_ID: -4}"; SUB_NAME="(redacted)"
fi
jq -n --arg subName "$SUB_NAME" --arg subId "$SUB_ID" --arg filter "$FILTER" --argjson redacted "$REDACT" \
  --arg generated "$(date '+%Y-%m-%d %H:%M %Z')" \
  --slurpfile skus "$TMP/skus.json" --slurpfile quota "$TMP/quota.json" --slurpfile crg "$TMP/crg.json" \
  --slurpfile regions "$TMP/regions.json" \
  '{subName:$subName, subId:$subId, regions:($regions[0] | map(.region)), regionInfo:$regions[0],
    filter:$filter, generated:$generated, redacted:$redacted, skus:$skus[0], quota:$quota[0], crg:$crg[0]}' -c \
  | sed -e 's/</\\u003c/g' -e 's/>/\\u003e/g' -e 's/&/\\u0026/g' > "$TMP/data.json"

{
cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src __SCRIPT_SRC__; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="no-referrer"><meta name="robots" content="noindex,nofollow">
<title>Azure VM SKU Availability Report</title>
<style>
:root{--blue:#0078d4;--bg:#f5f7fa;--card:#fff;--txt:#1b1f24;--mut:#5f6b7a;--ok:#107c10;--warn:#8a5a00;--bad:#c50f1f;--risk:#b4400a;--info:#005a9e}
*{box-sizing:border-box}body{margin:0;font-family:"Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--txt)}
header{background:var(--blue);color:#fff;padding:20px 28px}header h1{margin:0 0 4px;font-size:22px}header p{margin:0;opacity:.9;font-size:13px}header p.conf{margin-top:6px;font-size:11.5px;font-weight:600;letter-spacing:.02em}
main{padding:20px 28px;max-width:1700px;margin:auto}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:12px}
.card{background:var(--card);border-radius:8px;padding:12px 16px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.card .n{font-size:24px;font-weight:600}.card .l{font-size:12px;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
.card.fail .n{color:var(--bad)}.card.warn .n{color:var(--warn)}.card.risk .n{color:var(--risk)}.card.ok .n{color:var(--ok)}
.top{background:#fff;border-left:4px solid var(--bad);border-radius:6px;padding:10px 14px;margin-bottom:14px;font-size:14px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.top.good{border-left-color:var(--ok)}.top small{color:var(--mut)}
.alert{background:#fff4ce;border-radius:6px;padding:8px 12px;margin-bottom:12px;font-size:13px}
.tabs{display:flex;gap:6px;margin-bottom:12px;flex-wrap:wrap}.tabs button{border:0;background:#e4e9f0;padding:8px 14px;border-radius:6px;cursor:pointer;font-size:14px}
.tabs button.on{background:var(--blue);color:#fff}
.filters{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:10px;align-items:center}
.filters input,.filters select{padding:7px 9px;border:1px solid #cdd5df;border-radius:6px;font-size:13px}
.filters label{font-size:13px;color:var(--mut)}
.wrap{background:var(--card);border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.08);overflow:auto;max-height:70vh}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{padding:7px 10px;border-bottom:1px solid #eef1f5;text-align:left;white-space:nowrap}
td.wrapc{white-space:normal;min-width:260px;max-width:420px}td.notes{white-space:normal;min-width:300px;max-width:560px;color:var(--mut);font-size:12px}
th{position:sticky;top:0;background:#f0f3f7;cursor:pointer;user-select:none;z-index:1}th:hover{background:#e3e8ef}
td.num{text-align:right;font-variant-numeric:tabular-nums}
tr.sev-fail td:first-child{box-shadow:inset 4px 0 var(--bad)}tr.sev-warn td:first-child{box-shadow:inset 4px 0 #e0a800}
tr.sev-risk td:first-child{box-shadow:inset 4px 0 var(--risk)}tr.sev-info td:first-child{box-shadow:inset 4px 0 var(--info)}tr.sev-ok td:first-child{box-shadow:inset 4px 0 var(--ok)}
.pill{padding:2px 8px;border-radius:10px;font-size:12px;font-weight:600;display:inline-block}
.Available,.Yes,.ok{background:#dff6dd;color:var(--ok)}.PartiallyAvailable,.Unknown,.warn{background:#fff4ce;color:var(--warn)}
.NotAvailable,.No,.fail{background:#fde7e9;color:var(--bad)}.risk{background:#fde9dc;color:var(--risk)}.info{background:#deecf9;color:var(--info)}
a.pill{text-decoration:none;white-space:normal}a.pill:hover{text-decoration:underline}
code.ec{font-size:11px;background:#f0f3f7;padding:1px 5px;border-radius:4px;color:#333}
.bar{background:#e4e9f0;border-radius:4px;height:8px;width:120px;display:inline-block;vertical-align:middle;margin-right:6px}
.bar i{display:block;height:8px;border-radius:4px;background:var(--blue)}.bar i.hi{background:var(--bad)}
.note{font-size:12px;color:var(--mut);margin-top:14px;line-height:1.5}.hide{display:none}.count{font-size:12px;color:var(--mut);margin-left:auto}
button.dl{border:1px solid var(--blue);color:var(--blue);background:#fff;padding:6px 12px;border-radius:6px;cursor:pointer}
#help{background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.08);padding:6px 26px 20px;line-height:1.55;font-size:14px;max-width:1150px}
#help h2{font-size:18px;margin:22px 0 6px;border-bottom:1px solid #eef1f5;padding-bottom:4px}#help h3{font-size:15px;margin:14px 0 4px}
#help pre{background:#1e1e1e;color:#e6e6e6;padding:10px 12px;border-radius:6px;overflow:auto;font-size:12.5px;line-height:1.45}
#help td,#help th{white-space:normal;vertical-align:top}#help th{position:static;cursor:default}
#help .toc a{margin-right:12px;font-size:13px}#help li{margin:2px 0}
:target{scroll-margin-top:10px}
</style></head><body>
<header><h1>Azure VM SKU Availability Report</h1><p id="meta"></p>
<p class="conf">CONFIDENTIAL: contains subscription details and quota for your organisation. Share only with people who need it (re-run with -r to mask the subscription).</p></header>
<main>
<div class="cards" id="cards"></div>
<div class="top" id="top"></div>
<div id="alerts"></div>
<div class="tabs"><button class="on" data-t="skus">VM SKUs</button><button data-t="quota">vCPU Quota</button><button data-t="crg">Capacity Reservations</button><button data-t="help">Troubleshooting &amp; Help</button></div>

<section id="skus">
<div class="filters">
 <input id="q" placeholder="Search SKU or family…" size="24">
 <select id="fRegion"><option value="">All regions</option></select>
 <select id="fSev"><option value="">Any outcome</option><option value="fail">Will fail</option><option value="warn">Warning (zone / quota)</option><option value="risk">Allocation risk</option><option value="info">Deploys (zone notes)</option><option value="ok">Will deploy</option><option value="deployable">Deployable (not fail)</option></select>
 <select id="fCat"><option value="">Any reason</option></select>
 <select id="fStatus"><option value="">Any status</option><option>Available</option><option>PartiallyAvailable</option><option>NotAvailable</option></select>
 <label>Min vCPUs <input id="minCpu" type="number" min="0" style="width:64px"></label>
 <label>Min memory GB <input id="minMem" type="number" min="0" style="width:72px"></label>
 <button class="dl" id="csv">Download CSV</button>
 <span class="count" id="count"></span>
</div>
<div class="wrap"><table id="t"><thead><tr>
 <th data-k="region">Region</th><th data-k="sku">SKU</th><th data-k="sevRank">Predicted outcome</th><th data-k="code">Azure error code</th>
 <th data-k="family">Family</th><th data-k="vcpus">vCPUs</th><th data-k="memGB">Memory GB</th>
 <th data-k="gpus">GPUs</th><th data-k="zones">Zones</th><th data-k="restrictedZones">Restricted zones</th>
 <th data-k="status">Status</th><th data-k="famUsed">Family used</th><th data-k="famLimit">Family limit</th><th data-k="famFree">Family free</th>
 <th data-k="regFree">Regional free</th><th data-k="maxVMs">Max VMs (quota)</th><th data-k="canDeploy">Can deploy 1</th><th data-k="reason">Restriction reason</th><th data-k="notes">Other notes</th>
</tr></thead><tbody></tbody></table></div>
<p class="note" id="trunc"></p>
</section>

<section id="quota" class="hide">
<div class="filters"><input id="qq" placeholder="Search quota…" size="26"><select id="qRegion"><option value="">All regions</option></select>
<label><input type="checkbox" id="qUsed"> Only in use</label><label><input type="checkbox" id="qZero"> Only limit 0</label><label><input type="checkbox" id="qRel"> Only families in SKU list</label><span class="count" id="qcount"></span></div>
<div class="wrap"><table id="qt"><thead><tr><th data-k="region">Region</th><th data-k="name">Quota</th><th data-k="used">Used</th><th data-k="limit">Limit</th><th data-k="free">Free</th><th data-k="pct">Usage</th></tr></thead><tbody></tbody></table></div>
</section>

<section id="crg" class="hide">
<div class="wrap"><table id="ct"><thead><tr><th>Group</th><th>Resource group</th><th>Reservation</th><th>Region</th><th>SKU</th><th>Reserved VMs</th><th>Zones</th></tr></thead><tbody></tbody></table></div>
<p class="note">Reserved capacity is billed whether or not VMs use it. To check how much is in use: <code>az capacity reservation show -g &lt;rg&gt; -c &lt;group&gt; -n &lt;reservation&gt; --instance-view</code>.</p>
</section>

<section id="help" class="hide">
<p class="toc"><b>Jump to:</b>
<a href="#h-remediation">Remediation guide</a><a href="#h-how">How predictions work</a><a href="#h-check">Pre-deployment checklist</a><a href="#h-restricted">SKU restricted</a><a href="#h-quota">Quota</a>
<a href="#h-zonal">Zones</a><a href="#h-alloc">Allocation failures</a><a href="#h-crg">Capacity reservations</a><a href="#h-spot">Spot</a><a href="#h-other">Other checks</a><a href="#h-docs">Docs</a></p>

<h2 id="h-how">How the predictions work</h2>
<p>Each SKU gets one <b>predicted outcome</b> (the most serious problem found) and the error code Azure returns for it. Other problems for the same SKU are listed under <b>Other notes</b>. The order of checks:</p>
<table><thead><tr><th>Outcome</th><th>What the script checked</th><th>Error the customer sees</th></tr></thead><tbody>
<tr><td><span class="pill fail">SKU restricted</span></td><td><code>az vm list-skus</code> shows a <i>Location</i> restriction (reason <code>NotAvailableForSubscription</code>, or <code>QuotaId</code> when the subscription offer type can't use that size).</td><td><code class="ec">SkuNotAvailable</code> (ARM/Bicep validation shows <code class="ec">InvalidTemplateDeployment</code> wrapping it)</td></tr>
<tr><td><span class="pill fail">Family quota is 0 / exceeded</span></td><td>Family vCPU limit minus current usage is less than the SKU's vCPUs.</td><td><code class="ec">OperationNotAllowed</code> or <code class="ec">QuotaExceeded</code>, "Operation could not be completed as it results in exceeding approved &lt;family&gt; Cores quota"</td></tr>
<tr><td><span class="pill fail">Regional quota exceeded</span></td><td>"Total Regional vCPUs" free is less than the SKU's vCPUs.</td><td>Same codes; the message names Total Regional Cores</td></tr>
<tr><td><span class="pill warn">Zonal deploy fails in zone X</span></td><td>A <i>Zone</i> restriction blocks the SKU in some or all zones.</td><td><code class="ec">SkuNotAvailable</code> "...not available in location 'X' zones 'N'"</td></tr>
<tr><td><span class="pill info">Only offered in zone(s) / no zone support</span></td><td>The SKU is offered in fewer zones than the region has, or in none.</td><td><code class="ec">SkuNotAvailable</code> only if you pin a zone the SKU isn't in</td></tr>
<tr><td><span class="pill warn">Quota unknown / tight</span></td><td>The family wasn't in <code>az vm list-usage</code>, or only 1–2 VMs fit.</td><td>Quota errors when you scale out</td></tr>
<tr><td><span class="pill risk">Allocation risk</span></td><td>Rule of thumb only: GPU (N-series), HPC (H-series), M-series, legacy sizes (Av1, Dv1, DSv1, D15_v2, G), very large sizes (64+ vCPUs or 512+ GB), or sizes offered in a single zone.</td><td>Possible <code class="ec">AllocationFailed</code>, <code class="ec">ZonalAllocationFailed</code>, <code class="ec">OverconstrainedAllocationRequest</code>, <code class="ec">OverconstrainedZonalAllocationRequest</code></td></tr>
<tr><td><span class="pill ok">Will deploy</span></td><td>No restriction and at least one VM fits in both quotas.</td><td>None expected. Allocation can still fail: Azure doesn't publish free hardware capacity.</td></tr>
</tbody></table>

<h2 id="h-check">Pre-deployment checklist</h2>
<p>Run these in Cloud Shell for the exact size, region and subscription you plan to use (values below are filled in from this report; change them as needed):</p>
<pre id="chk"></pre>
<p>Tip: validate a whole deployment without creating anything with <code>az deployment group validate</code> (or <code>what-if</code>). It catches <code>SkuNotAvailable</code> and many quota errors before deploy, but not allocation failures.</p>

<h2 id="h-restricted">SKU restricted: <code>SkuNotAvailable</code></h2>
<h3>Confirm</h3>
<pre id="cmdRestricted"></pre>
<p>Look at the <b>Restrictions</b> column. <code>NotAvailableForSubscription, type: Location</code> means the size is blocked in the whole region for this subscription. <code>type: Zone</code> lists the blocked zones. <code>QuotaId</code> means the subscription's offer type (for example a free trial or some sponsored offers) can't use this size.</p>
<h3>Fix</h3>
<ul>
<li>Pick another size with similar specs that isn't restricted (filter this report by <i>Will deploy</i> and min vCPUs / memory), or another region.</li>
<li>To enable the size: Azure portal &gt; <b>Help + support</b> &gt; <b>Create a support request</b>. Issue type <b>Service and subscription limits (quotas)</b>, quota type <b>Compute-VM (cores-vCPUs) subscription limit increases</b>. Choose the region and VM series and give the vCPU limit you need. Microsoft calls this a SKU request.</li>
<li>For <code>QuotaId</code>, the fix is usually a different subscription offer (for example moving from a free trial to pay-as-you-go).</li>
</ul>

<h2 id="h-quota">vCPU quota: <code>OperationNotAllowed</code> / <code>QuotaExceeded</code></h2>
<p>Azure enforces two vCPU quotas per subscription per region, and a VM must fit in <b>both</b>: the <b>VM-family</b> quota (for example "Standard DSv5 Family vCPUs") and <b>Total Regional vCPUs</b>. Spot VMs use a separate "Total Regional Low-priority vCPUs" quota. A family quota of <b>0</b> means you must request quota before the first VM.</p>
<h3>Confirm</h3>
<pre id="cmdQuota"></pre>
<h3>Fix</h3>
<ul>
<li><b>Portal:</b> search <b>Quotas</b> &gt; <b>Compute</b> (My quotas), select the family and region &gt; <b>New Quota Request</b>. Or Subscriptions &gt; your subscription &gt; <b>Usage + quotas</b> &gt; <b>Request increase</b>. Many requests are approved automatically within minutes. If it's rejected you get a link to open a support request.</li>
<li>Approving a family increase also raises Total Regional vCPUs if needed. If only the regional quota is short, request a regional increase.</li>
<li><b>CLI</b> (needs the <code>quota</code> extension; <code>az extension add --name quota</code>):</li>
</ul>
<pre id="cmdQuotaFix"></pre>
<ul><li>Or free quota: delete unused VMs. Note that <i>stopped (deallocated)</i> VMs don't count toward vCPU quota, but VMs that are only stopped (still allocated) do.</li></ul>

<h2 id="h-zonal">Zone restrictions and zone-pinned sizes</h2>
<ul>
<li>A <i>Zone</i> restriction blocks only deployments pinned to those zones (<code>--zone N</code> / <code>zones: ["N"]</code>). Use a zone listed as OK in the outcome. If every zone is restricted, deploy without a zone, or file the same support request as above and name the zones you need.</li>
<li>Some sizes are only offered in some zones (see the <b>Zones</b> column). Pinning a VM to a zone where the size isn't offered fails with <code>SkuNotAvailable</code>. For a zone-redundant design, choose a size that is offered in all the zones you need.</li>
<li>Zone numbers are mapped per subscription: zone "1" in one subscription might not be the same datacenter as zone "1" in another. Check this report for each subscription.</li>
<li>A size with an empty Zones column has no zone support in that region. Deploy it as a regional (non-zonal) VM.</li>
</ul>

<h2 id="h-alloc">Allocation failures: <code>AllocationFailed</code>, <code>ZonalAllocationFailed</code>, <code>OverconstrainedAllocationRequest</code></h2>
<p>These mean Azure doesn't have free hardware for the size in that region, zone or cluster <i>right now</i>. Quota and restrictions can be fine. No API shows free capacity ahead of time, so the "Allocation risk" flag is only a hint. Try these fixes in order:</p>
<ol>
<li><b>Retry later.</b> Capacity frees up as other customers deallocate VMs.</li>
<li><b>Try another size</b>, ideally a newer generation or another size in the same family (for example v5 instead of v3, or an AMD <code>a</code> size instead of Intel). The error message often suggests alternative sizes and zones. Use them.</li>
<li><b>Try another zone, or no zone.</b> A regional (non-zonal) VM can be placed anywhere in the region.</li>
<li><b>Try another region.</b></li>
<li><b>Remove constraints</b> (<code>Overconstrained*</code> errors): turn off accelerated networking, remove the VM from its proximity placement group, and drop UltraSSD or Premium SSD v2 disks. Each one narrows the hardware Azure can use.</li>
<li><b>Availability sets:</b> resizing, adding VMs, or starting some of the VMs in a set must happen on the cluster that already hosts the set. Stop (deallocate) <b>all</b> VMs in the set, then start them together so Azure can choose any cluster. Or create the new VM in a different availability set.</li>
<li><b>Proximity placement groups:</b> deallocate all VMs in the group, then start the most restrictive size (for example a GPU or M-series VM) first.</li>
<li><b>Scale sets with a single placement group</b> are limited to one cluster. Use <code>singlePlacementGroup=false</code> where your workload allows it.</li>
<li><b>Legacy sizes</b> (Av1, Dv1, DSv1, D15_v2, G) run on older hardware that is shrinking. Move to the current equivalents (Av2, Dv3/Dv5 and so on).</li>
<li><b>Need guaranteed capacity?</b> Use an on-demand capacity reservation (next section).</li>
</ol>
<pre id="cmdAlloc"></pre>

<h2 id="h-crg">Capacity reservations: guaranteed capacity</h2>
<p>An on-demand capacity reservation holds capacity for a given size, count and (optionally) zone. The SLA applies once the reservation succeeds. You pay the pay-as-you-go price for reserved capacity whether or not VMs are using it, and reserved instance discounts can apply to it. Creating the reservation can itself fail if there's no capacity, so create it before you need it. It also uses vCPU quota, and sponsored and free-trial subscriptions can't use it.</p>
<pre id="cmdCrg"></pre>

<h2 id="h-spot">Spot VMs aren't a capacity fix</h2>
<p>Spot VMs run on spare capacity. Azure can evict them with 30 seconds' notice when it needs the capacity back, and they have no SLA. When a region is short on hardware, Spot capacity is usually the first to go. Spot also uses its own Low-priority vCPU quota. Use Spot for interruptible work, not to get around <code>AllocationFailed</code>.</p>

<h2 id="h-other">Other checks before you deploy</h2>
<ul>
<li><b>VM generation:</b> "Gen2 images only" in Other notes means the size supports only Generation 2 VMs, so use a Gen2 image. Some sizes are Gen1 only.</li>
<li><b>Accelerated networking:</b> if a size doesn't support it (see Other notes), turn it off on the NIC or choose another size.</li>
<li><b>Disks and NICs:</b> the maximum number of data disks and NICs depends on the size. Check the size's docs page.</li>
<li><b>Resizing a running VM:</b> if the new size isn't available on the current cluster, deallocate the VM first and then resize.</li>
<li>This report is a point-in-time snapshot. Restrictions and quota change, so re-run it before large deployments.</li>
</ul>

<h2 id="h-remediation">Remediation: step-by-step fixes per outcome</h2>
<p>Click the <b>Predicted outcome</b> pill for a SKU to jump to its remediation steps, or expand a category below. Commands are filled in from the SKU table where practical; substitute <code>&lt;region&gt;</code>, <code>&lt;size&gt;</code> and <code>&lt;family&gt;</code> when needed.</p>

<h3 id="rem-restricted">1. SKU restricted (SkuNotAvailable / InvalidTemplateDeployment)</h3>
<ol>
<li>Confirm: <code>az vm list-skus -l &lt;region&gt; --size &lt;size&gt; --all -o table</code> and read the Restrictions column.</li>
<li>NotAvailableForSubscription: pick a sibling size in the same family (e.g. v5 instead of v4) or a region where Restrictions is empty.</li>
<li>Need that exact size/region: open an Azure support request, type <b>Service and subscription limits (quotas)</b>, and ask to enable the SKU in that region.</li>
<li>QuotaId: the subscription offer type (free trial, MSDN/Visual Studio) can't use the size. Pick an allowed size or deploy from a Pay-As-You-Go/EA subscription.</li>
<li>ARM/Bicep: look inside InvalidTemplateDeployment for the inner SkuNotAvailable; parameterize the VM size so it can be swapped without editing the template.</li>
</ol>

<h3 id="rem-quota0">2. Family quota is 0 / exceeded (QuotaExceeded / OperationNotAllowed)</h3>
<ol>
<li><code>az vm list-usage -l &lt;region&gt; -o table</code>; find the family row (e.g. "Standard DSv5 Family vCPUs").</li>
<li>Needed = current usage + (SKU vCPUs × VM count).</li>
<li>Portal &gt; <b>Quotas</b> &gt; <b>Compute</b>, filter region + family, <b>New quota request</b>. Small increases are often auto-approved in minutes.</li>
<li>Meanwhile free quota by deallocating/deleting unused VMs in that family (Stopped but not deallocated still holds cores) or use a family with headroom.</li>
</ol>

<h3 id="rem-regquota">3. Regional quota exceeded (Total Regional Cores)</h3>
<ol>
<li>In the same list-usage output check "Total Regional vCPUs".</li>
<li>Request an increase on Total Regional vCPUs on the same Quotas page; it must be at least as high as the family request since both must fit.</li>
<li>Meanwhile deallocate idle VMs anywhere in that region or deploy to another region.</li>
<li>Spot VMs use "Total Regional Low-priority vCPUs", a separate limit.</li>
</ol>

<h3 id="rem-zonal">4. Zonal deploy fails in zone X (SkuNotAvailable ... zones 'N')</h3>
<ol>
<li><code>az vm list-skus -l &lt;region&gt; --size &lt;size&gt; --zone -o table</code> to see which zones offer it.</li>
<li>Change the deployment's <code>zones</code> to an allowed zone, or remove the zone pin if zonal placement isn't required.</li>
<li>If you need all 3 zones for HA, choose a size offered in every zone.</li>
<li>Scale sets: set <code>zones</code> only to supported zones; enable zone balancing only if every zone supports the size.</li>
</ol>

<h3 id="rem-zonepinned">5. Only offered in some zones / no zone support</h3>
<ol>
<li>Don't hard-code a zone; read supported zones from list-skus and parameterize.</li>
<li>No zone support: deploy regionally and get resilience from an availability set or a second region.</li>
<li>If zonal resilience is required, pick a size available in all zones.</li>
</ol>

<h3 id="rem-quotaunknown">6. Quota unknown / tight</h3>
<ol>
<li>Family missing from list-usage usually means limit 0: treat as case 2 and request quota before deploying.</li>
<li>If only 1-2 VMs fit, request quota for peak scale + ~20% so autoscale doesn't fail.</li>
<li>Create quota alerts (Portal &gt; <b>Quotas</b> &gt; <b>Create alert rule</b>) at ~80% usage.</li>
</ol>

<h3 id="rem-alloc">7. Allocation risk (AllocationFailed, ZonalAllocationFailed, OverconstrainedAllocationRequest, OverconstrainedZonalAllocationRequest)</h3>
<ol>
<li>Retry after a short wait; capacity changes often.</li>
<li>Relax constraints: remove zone pin, proximity placement group, accelerated networking requirement, or availability-set tie.</li>
<li>Try a nearby newer-generation size (legacy Av1/Dv1/DSv1/G have the least capacity) or another region.</li>
<li>VM in an availability set fails: deallocate every VM in the set, then start them together so Azure can move the set to a cluster with room.</li>
<li>GPU/HPC/M-series/64+ vCPU sizes you can't afford to fail: buy an On-Demand Capacity Reservation.</li>
</ol>

<h3 id="rem-ok">8. Will deploy</h3>
<p>No action needed. Azure doesn't publish free capacity, so keep the retry + fallback-size plan from case 7 in your pipeline anyway.</p>

<h2 id="h-docs">Microsoft Learn docs</h2>
<ul>
<li><a href="https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/error-sku-not-available" target="_blank" rel="noopener">Resolve errors for SKU not available</a></li>
<li><a href="https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/error-resource-quota" target="_blank" rel="noopener">Resolve errors for resource quotas</a></li>
<li><a href="https://learn.microsoft.com/en-us/azure/quotas/per-vm-quota-requests" target="_blank" rel="noopener">Increase VM-family vCPU quotas</a> · <a href="https://learn.microsoft.com/en-us/azure/quotas/regional-quota-requests" target="_blank" rel="noopener">Increase regional vCPU quotas</a> · <a href="https://learn.microsoft.com/en-us/azure/virtual-machines/quotas" target="_blank" rel="noopener">vCPU quotas</a></li>
<li><a href="https://learn.microsoft.com/en-us/cli/azure/quota" target="_blank" rel="noopener">az quota CLI reference</a></li>
<li><a href="https://learn.microsoft.com/en-us/troubleshoot/azure/general/region-access-request-process" target="_blank" rel="noopener">Azure region access request process</a></li>
<li><a href="https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/allocation-failure" target="_blank" rel="noopener">Troubleshoot allocation failures when you create or resize VMs</a> (Linux and Windows)</li>
<li><a href="https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/restart-resize-error-troubleshooting" target="_blank" rel="noopener">Allocation failures when restarting or resizing existing VMs</a></li>
<li><a href="https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-overview" target="_blank" rel="noopener">On-demand capacity reservation</a></li>
<li><a href="https://learn.microsoft.com/en-us/azure/virtual-machines/co-location" target="_blank" rel="noopener">Proximity placement groups</a> · <a href="https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview" target="_blank" rel="noopener">Accelerated networking</a> · <a href="https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2" target="_blank" rel="noopener">Generation 2 VMs</a></li>
<li><a href="https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms" target="_blank" rel="noopener">Azure Spot VMs</a> · <a href="https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/overview" target="_blank" rel="noopener">VM sizes overview</a> · <a href="https://learn.microsoft.com/en-us/azure/reliability/availability-zones-service-support" target="_blank" rel="noopener">Availability zone service support</a></li>
</ul>
</section>

<p class="note"><b>How to read this.</b> <b>Predicted outcome</b> combines SKU restrictions and vCPU quota for this subscription, and links to the matching help topic.
<b>Status</b>: NotAvailable means the SKU is blocked in that region. PartiallyAvailable means it is blocked in some availability zones.
<b>Can deploy 1</b> is Yes when the SKU isn't restricted and one VM fits in both the family and regional vCPU quota.
Quota is a limit, not a guarantee of physical capacity, so a deployment can still fail with <code>AllocationFailed</code>.
Capacity reservations are the only way to guarantee capacity in advance.</p>
</main>
HTML_HEAD
} > "$TMP/head.html"

{
printf '\nconst D =\n'
cat "$TMP/data.json"
cat <<'HTML_TAIL'
;
const $=s=>document.querySelector(s), esc=v=>v==null?"":String(v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const MAX_ROWS=2000, SEV_RANK={fail:0,warn:1,risk:2,info:3,ok:4};
const CAT_LABEL={restricted:"SKU restricted",quota0:"Family quota is 0",famquota:"Family quota exceeded",regquota:"Regional quota exceeded",
 zonal:"Zone restricted",zonepinned:"Only in some zones",nozones:"No zone support",quotaunknown:"Quota unknown",alloc:"Allocation risk",quotatight:"Quota tight",ok:"Will deploy"};
const CAT_HELP={restricted:"rem-restricted",quota0:"rem-quota0",famquota:"rem-quota0",regquota:"rem-regquota",zonal:"rem-zonal",zonepinned:"rem-zonepinned",nozones:"rem-zonepinned",
 quotaunknown:"rem-quotaunknown",alloc:"rem-alloc",quotatight:"rem-quotaunknown",ok:"rem-ok"};
$("#meta").textContent=`Subscription: ${D.subName} (${D.subId}) · Regions: ${D.regions.join(", ")}${D.filter?" · Filter: "+D.filter:""} · Generated ${D.generated}`;
const S=D.skus.map(s=>({...s,sevRank:SEV_RANK[s.sev]??9})), cnt=f=>S.filter(f).length;
const nFail=cnt(s=>s.sev=="fail");
const cards=[["SKUs checked",S.length,""],["Will deploy",cnt(s=>s.sev=="ok"||s.sev=="info"),"ok"],["Will fail",nFail,"fail"],
 ["Zone / quota warnings",cnt(s=>s.sev=="warn"),"warn"],["Allocation risk",cnt(s=>s.sev=="risk"),"risk"],
 ["Restricted",cnt(s=>s.status=="NotAvailable"),""],["Capacity reservations",D.crg.length,""]];
$("#cards").innerHTML=cards.map(([l,n,c])=>`<div class="card ${c}"><div class="n">${n}</div><div class="l">${l}</div></div>`).join("");
// One-line top issues summary
(()=>{const by={};S.forEach(s=>{if(s.sev=="fail")by[s.cat]=(by[s.cat]||0)+1;});
 const parts=Object.entries(by).sort((a,b)=>b[1]-a[1]).map(([c,n])=>`${n} ${CAT_LABEL[c]||c}`);
 const zw=cnt(s=>s.cat=="zonal"), ar=cnt(s=>s.sev!="fail"&&(s.sev=="risk"||/Allocation risk/.test(s.notes||""))), ok=cnt(s=>s.sev!="fail");
 const el=$("#top");
 if(!S.length){el.innerHTML="<b>Top issues:</b> no SKUs were returned. Check the region names, the -f filter and the subscription.";return;}
 el.classList.toggle("good",nFail==0);
 el.innerHTML=`<b>Top issues:</b> ${nFail} of ${S.length} SKUs will fail${parts.length?" ("+esc(parts.join(", "))+")":""}`+
  `${zw?`; ${zw} blocked in some zones`:""}${ar?`; ${ar} deployable SKUs at higher allocation risk`:""}; ${ok} can deploy. `+
  `<small>Based on restrictions and quota only; any SKU can still hit AllocationFailed. See <a href="#h-how" data-goto="h-how">Troubleshooting &amp; Help</a>.</small>`;})();
// Region warnings (empty / failed regions)
(()=>{const bad=(D.regionInfo||[]).filter(r=>r.error||r.skus==0);
 if(bad.length)$("#alerts").innerHTML=`<div class="alert"><b>Regions with no data:</b> `+bad.map(r=>`${esc(r.region)} (${r.error?"query failed: "+esc(r.error):"no VM SKUs returned; the region may not be enabled for this subscription, or the filter matched nothing"})`).join("; ")+`</div>`;})();
function show(id){document.querySelectorAll(".tabs button").forEach(x=>x.classList.toggle("on",x.dataset.t==id));
 ["skus","quota","crg","help"].forEach(t=>$("#"+t).classList.toggle("hide",t!=id));}
document.querySelectorAll(".tabs button").forEach(b=>b.onclick=()=>show(b.dataset.t));
document.addEventListener("click",e=>{const a=e.target.closest("[data-goto]");if(!a)return;e.preventDefault();show("help");
 const t=document.getElementById(a.dataset.goto);if(t)t.scrollIntoView({behavior:"smooth"});});
for(const r of D.regions){$("#fRegion").add(new Option(r,r));$("#qRegion").add(new Option(r,r));}
for(const c of Object.keys(CAT_LABEL)) if(S.some(s=>s.cat==c)) $("#fCat").add(new Option(CAT_LABEL[c],c));
const pill=v=>`<span class="pill ${esc(String(v).split(" ")[0])}">${esc(v)}</span>`;
const outcome=s=>`<a href="#${CAT_HELP[s.cat]||"h-how"}" data-goto="${CAT_HELP[s.cat]||"h-how"}" class="pill ${esc(s.sev)}" title="How to fix">${esc(s.outcome)}</a>`;
function sorter(tbl,state,render){tbl.querySelectorAll("th[data-k]").forEach(th=>th.onclick=()=>{state.dir=state.key==th.dataset.k?-state.dir:1;state.key=th.dataset.k;render();});}
const cmp=(k,d)=>(a,b)=>{let x=a[k],y=b[k];const ex=x==null||x==="",ey=y==null||y==="";if(ex&&ey)return 0;if(ex)return 1;if(ey)return -1;
 const nx=Number(x),ny=Number(y);return (!isNaN(nx)&&!isNaN(ny)?nx-ny:String(x).localeCompare(String(y)))*d;};
let ss={key:"sevRank",dir:1}, shown=[];
function renderSkus(){const q=$("#q").value.toLowerCase(),r=$("#fRegion").value,st=$("#fStatus").value,sv=$("#fSev").value,ct=$("#fCat").value,
 mc=+$("#minCpu").value||0,mm=+$("#minMem").value||0;
 shown=S.filter(s=>(!q||(s.sku+" "+s.family).toLowerCase().includes(q))&&(!r||s.region==r)&&(!st||s.status==st)
  &&(!sv||(sv=="deployable"?s.sev!="fail":s.sev==sv))&&(!ct||s.cat==ct)&&s.vcpus>=mc&&s.memGB>=mm).sort(cmp(ss.key,ss.dir));
 $("#t tbody").innerHTML=shown.slice(0,MAX_ROWS).map(s=>`<tr class="sev-${esc(s.sev)}"><td>${esc(s.region)}</td><td><b>${esc(s.sku)}</b></td>
 <td class="wrapc">${outcome(s)}</td><td>${s.code?`<code class="ec">${esc(s.code)}</code>`:""}</td><td>${esc(s.family)}</td><td class="num">${s.vcpus}</td>
 <td class="num">${s.memGB}</td><td class="num">${esc(s.gpus)}</td><td>${esc(s.zones)}</td><td>${esc(s.restrictedZones)}</td>
 <td>${pill(s.status)}</td><td class="num">${esc(s.famUsed)}</td><td class="num">${esc(s.famLimit)}</td><td class="num">${esc(s.famFree)}</td>
 <td class="num">${esc(s.regFree)}</td><td class="num">${s.maxVMs==null?"–":esc(s.maxVMs)}</td><td>${pill(s.canDeploy)}</td><td>${esc(s.reason)}</td><td class="notes">${esc(s.notes)}</td></tr>`).join("");
 $("#count").textContent=`${shown.length} of ${S.length} SKUs`;
 $("#trunc").textContent=shown.length>MAX_ROWS?`Showing the first ${MAX_ROWS} of ${shown.length} matching rows. Use the filters to narrow the list; Download CSV includes every matching row.`:"";}
["#q","#fRegion","#fStatus","#fSev","#fCat","#minCpu","#minMem"].forEach(id=>$(id).oninput=renderSkus);
sorter($("#t"),ss,renderSkus);
$("#csv").onclick=()=>{const keys=["region","sku","outcome","code","sev","family","vcpus","memGB","gpus","maxDisks","zones","restrictedZones","status","famUsed","famLimit","famFree","regFree","maxVMs","canDeploy","reason","notes"];
 const cell=v=>{let t=String(v??"");if(/^[=+\-@\t\r]/.test(t)&&!/^-?\d+(\.\d+)?$/.test(t))t="'"+t;return `"${t.replace(/"/g,'""')}"`;};
 const csv=[keys.join(",")].concat(shown.map(s=>keys.map(k=>cell(s[k])).join(","))).join("\r\n");
 const a=document.createElement("a");a.href=URL.createObjectURL(new Blob([csv],{type:"text/csv"}));a.download="azure-vm-skus.csv";a.click();};
const famKeys=new Set(S.map(s=>(s.region+"|"+s.family).toLowerCase()));
const Q=D.quota.map(q=>({...q,pct:q.limit?Math.round(q.used/q.limit*100):(q.used>0?100:0)})); let qs={key:"pct",dir:-1};
function renderQuota(){const q=$("#qq").value.toLowerCase(),r=$("#qRegion").value,u=$("#qUsed").checked,z=$("#qZero").checked,rel=$("#qRel").checked;
 const rows=Q.filter(x=>(!q||String(x.name).toLowerCase().includes(q))&&(!r||x.region==r)&&(!u||x.used>0)&&(!z||x.limit==0)
  &&(!rel||famKeys.has((x.region+"|"+x.key).toLowerCase())||x.key=="cores")).sort(cmp(qs.key,qs.dir));
 $("#qt tbody").innerHTML=rows.map(x=>`<tr><td>${esc(x.region)}</td><td>${esc(x.name)}</td><td class="num">${esc(x.used)}</td><td class="num">${esc(x.limit)}</td>
 <td class="num">${esc(x.free)}</td><td>${x.limit==0?`<span class="pill fail">limit 0 – request increase</span>`:
 `<span class="bar"><i class="${x.pct>=80?"hi":""}" style="width:${Math.min(x.pct,100)}%"></i></span>${x.pct}%`}</td></tr>`).join("");
 $("#qcount").textContent=`${rows.length} quotas`;}
["#qq","#qRegion","#qUsed","#qZero","#qRel"].forEach(id=>$(id).oninput=renderQuota); sorter($("#qt"),qs,renderQuota);
$("#ct tbody").innerHTML=D.crg.length?D.crg.map(c=>`<tr><td>${esc(c.group)}</td><td>${esc(c.rg)}</td><td>${esc(c.name)}</td><td>${esc(c.region)}</td><td>${esc(c.sku)}</td>
 <td class="num">${esc(c.reserved)}</td><td>${esc(c.zones)}</td></tr>`).join(""):`<tr><td colspan="7">No capacity reservations found in this subscription.</td></tr>`;
// Help commands, filled in with this report's subscription, a region and an example SKU
(()=>{const ex=S.find(s=>s.sev=="fail")||S[0]||{region:D.regions[0]||"eastus",sku:"Standard_D4s_v5",family:"standardDSv5Family"};
 const safe=(v,ph)=>/^[A-Za-z0-9_.\-]{1,80}$/.test(String(v||""))?String(v):ph; // never put odd characters into copy-paste commands
 const R=safe(ex.region,"<region>"), K=safe(ex.sku,"<vm-size>"), F=safe(ex.family,"<family>"), SUB=D.redacted?"<subscription-id>":safe(D.subId,"<subscription-id>"), SC=`/subscriptions/${SUB}/providers/Microsoft.Compute/locations/${R}`;
 const set=(id,t)=>{const e=$("#"+id);if(e)e.textContent=t;};
 set("chk",`SUB=${SUB}    # passed with --subscription so your default az subscription is not changed
# 1. Is the size offered and unrestricted? (Restrictions column must be None, or exclude your zone)
az vm list-skus --subscription $SUB --location ${R} --size ${K} --all --output table
# 2. Is there enough family AND regional vCPU quota?
az vm list-usage --subscription $SUB --location ${R} --output table --query "[?contains(name.value,'${F}') || name.value=='cores']"
# 3. Validate the deployment without creating anything
az deployment group validate -g <resource-group> --template-file main.bicep`);
 set("cmdRestricted",`az vm list-skus --location ${R} --size ${K} --all --output table
# All restricted sizes in the region:
az vm list-skus --location ${R} --resource-type virtualMachines --all \\
  --query "[?restrictions[0]].{name:name, type:restrictions[0].type, reason:restrictions[0].reasonCode, zones:join(',',restrictions[0].restrictionInfo.zones || \`[]\`)}" -o table`);
 set("cmdQuota",`az vm list-usage --location ${R} --output table
# Only quotas that are full or at 0:
az vm list-usage --location ${R} -o json | jq -r '.[] | select((.limit|tonumber) - (.currentValue|tonumber) <= 0) | [.localName, .currentValue, .limit] | @tsv'`);
 set("cmdQuotaFix",`az extension add --name quota
az quota list   --scope ${SC} -o table            # exact resource names and limits
az quota show   --resource-name ${F} --scope ${SC}
az quota update --resource-name ${F} --scope ${SC} --limit-object value=<new-vCPU-limit> --resource-type dedicated
# Raise Total Regional vCPUs if that is the blocker (check its name in az quota list; usually "cores"):
az quota update --resource-name cores --scope ${SC} --limit-object value=<new-limit> --resource-type dedicated
az quota request status list --scope ${SC} -o table   # track the request`);
 set("cmdAlloc",`# Retry the same size in another zone / without a zone, or another size:
az vm create -g <rg> -n <vm> --image Ubuntu2204 --size ${K} --location ${R} --zone 2
az vm create -g <rg> -n <vm> --image Ubuntu2204 --size ${K} --location ${R}          # regional, no zone
# Availability set: deallocate ALL VMs, then start them together
az vm deallocate --ids $(az vm list -g <rg> --query "[?availabilitySet.id!=null].id" -o tsv)
az vm start      --ids $(az vm list -g <rg> --query "[?availabilitySet.id!=null].id" -o tsv)
# Which sizes can an existing VM / availability set move to?
az vm list-vm-resize-options -g <rg> -n <vm> -o table`);
 set("cmdCrg",`az capacity reservation group create -g <rg> -n crg-prod --location ${R} --zones 1 2 3
az capacity reservation create -g <rg> -c crg-prod -n res-${K.toLowerCase().replace(/_/g,"-")} --sku ${K} --capacity 5 --zone 1
az vm create -g <rg> -n <vm> --image Ubuntu2204 --size ${K} --zone 1 \\
  --capacity-reservation-group $(az capacity reservation group show -g <rg> -n crg-prod --query id -o tsv)`);})();
renderSkus(); renderQuota();
// Fill remediation commands when a SKU row is clicked
document.querySelector("#t tbody").addEventListener("click",e=>{
 const row=e.target.closest("tr");if(!row)return;const idx=[...row.parentNode.children].indexOf(row);
 if(idx<0||idx>=shown.length)return;const s=shown[idx];
 const R=esc(s.region),K=esc(s.sku),F=esc(s.family);
 document.querySelectorAll("#help code").forEach(c=>{
  let t=c.textContent.replace(/&lt;region&gt;/g,R).replace(/&lt;size&gt;/g,K).replace(/&lt;family&gt;/g,F);
  c.textContent=t.replace(/&lt;/g,"<").replace(/&gt;/g,">");
 });
});
if(location.hash=="#tab-help"){show("help");}
else if(location.hash.startsWith("#h-")||location.hash.startsWith("#rem-")){show("help");const t=document.getElementById(location.hash.slice(1));if(t)setTimeout(()=>t.scrollIntoView(),50);}
HTML_TAIL
} > "$TMP/script.js"

# Content-Security-Policy: allow only this exact inline script (sha256 hash); no network access at all
if command -v openssl >/dev/null; then
  SCRIPT_SRC="'sha256-$(openssl dgst -sha256 -binary "$TMP/script.js" | base64 | tr -d '\n')'"
else
  SCRIPT_SRC="'unsafe-inline'"
fi
{
  sed "s|__SCRIPT_SRC__|$SCRIPT_SRC|" "$TMP/head.html"
  printf '<script>'; cat "$TMP/script.js"; printf '</script></body></html>\n'
} > "$TMP/report.html"
mv -f "$TMP/report.html" "$OUTFILE"   # created under umask 077, so the report is 0600
chmod 600 "$OUTFILE" 2>/dev/null || true

echo "Report written to $OUTFILE ($(jq length "$TMP/skus.json") SKUs, $(jq '[.[] | select(.sev=="fail")] | length' "$TMP/skus.json") predicted to fail)" >&2
