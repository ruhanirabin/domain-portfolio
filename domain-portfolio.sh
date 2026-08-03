#!/usr/bin/env bash
# ============================================================
# domain-portfolio.sh — v1.0.0
# Author : Ruhani Rabin (https://www.ruhanirabin.com)
# Created: 2026-08-03
#
# Description:
# Consolidates domain portfolios from Porkbun and Cloudflare
# into a unified, deduplicated JSON + CSV report. Porkbun
# domains take priority as the purchase source. Duplicate
# Cloudflare DNS zones (pointing to Porkbun-owned domains)
# are removed. Each domain is enriched with auto-renew status,
# expiry date, and TLD-level annual renewal cost.
#
# Dependencies: bash, curl, jq, flock, install
#
# Usage:
#   ./domain-portfolio.sh
#
# Configuration (one of):
#   1. .env file beside the script (recommended)
#   2. Export vars: CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN,
#                   PORKBUN_API_KEY, PORKBUN_SECRET_API_KEY
#
# Output:
#   ./output/domains.json — combined deduplicated enriched JSON
#   ./output/domains.csv  — CSV for Google Sheets import
#
# For the Cloudflare TLD pricing source, see:
#   https://cfdomainpricing.com/  (public, no auth needed)
#
# License: MIT
# ============================================================

set -Eeuo pipefail
umask 077

# ── Configuration & Defaults ───────────────────────────────
readonly SCRIPT_NAME="domain-portfolio"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
readonly OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
readonly LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"
readonly LOCK_FILE="${LOCK_FILE:-${SCRIPT_DIR}/.${SCRIPT_NAME}.lock}"
readonly LOG_RETENTION_DAYS=7

readonly CF_API_BASE="https://api.cloudflare.com/client/v4"
readonly PB_API_BASE="https://api.porkbun.com/api/json/v3"
readonly CF_PRICING_URL="https://cfdomainpricing.com/prices.json"
readonly PER_PAGE=50
readonly PB_PAGE_SIZE=1000

readonly JSON_OUT="${OUTPUT_DIR}/domains.json"
readonly CSV_OUT="${OUTPUT_DIR}/domains.csv"

RUN_TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
RUN_LOG=""
TEMP_DIR=""
CF_REGISTRAR_API=""   # set after loading env (needs account_id)

# ── Shared Utilities ───────────────────────────────────────

log() {
    local lvl="$1" msg="$2"
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$lvl" "$msg" | tee -a "$RUN_LOG"
}

die() { log "ERROR" "$1"; exit 1; }

require_command() { command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }

cleanup() {
    local ec=$?
    [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf -- "$TEMP_DIR"
    [[ -n "$LOCK_FILE" && -f "$LOCK_FILE" ]] && rm -f -- "$LOCK_FILE"
    if (( ec != 0 )) && [[ -n "$RUN_LOG" ]]; then
        log "ERROR" "Run failed with exit code ${ec}."
    fi
}

prune_logs() {
    find "$LOG_DIR" -type f -name "${SCRIPT_NAME}-*.log" \
        -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
}

# ── Environment ────────────────────────────────────────────

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ENV_FILE"
    fi
    : "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required}"
    : "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
    : "${PORKBUN_API_KEY:?PORKBUN_API_KEY is required}"
    : "${PORKBUN_SECRET_API_KEY:?PORKBUN_SECRET_API_KEY is required}"

    [[ "$CLOUDFLARE_ACCOUNT_ID" =~ ^[A-Za-z0-9]{32}$ ]] \
        || die "CLOUDFLARE_ACCOUNT_ID must be 32-character identifier."
}

# ── Generic API Helpers ────────────────────────────────────

cf_api_get() {
    local url="$1" file="$2" code
    code="$(curl -sS --location --connect-timeout 15 --max-time 60 \
        --retry 3 --retry-delay 2 --retry-all-errors \
        -o "$file" -w '%{http_code}' \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Accept: application/json" "$url")" \
        || die "Cloudflare request failed: ${url}"
    if [[ "$code" != "200" ]]; then
        local err; err="$(jq -r '.errors//[]|map(.message)|join("; ")' "$file" 2>/dev/null||true)"
        die "Cloudflare HTTP ${code}: ${err:-unknown error}"
    fi
    jq -e '.success==true' "$file" >/dev/null || die "Cloudflare API returned unsuccessful."
}

cf_api_get_optional() {
    local url="$1" file="$2" code
    code="$(curl -sS --location --connect-timeout 15 --max-time 60 \
        --retry 2 --retry-delay 2 --retry-all-errors \
        -o "$file" -w '%{http_code}' \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Accept: application/json" "$url")" || { log "WARN" "Request failed: ${url}"; return 1; }
    [[ "$code" == "200" ]] && jq -e '.success==true' "$file" >/dev/null 2>&1 && return 0
    return 1
}

pb_api_get() {
    local url="$1" file="$2" code status msg
    code="$(curl -sS --location --connect-timeout 15 --max-time 90 \
        --retry 3 --retry-delay 2 --retry-all-errors \
        -o "$file" -w '%{http_code}' \
        -H "Accept: application/json" \
        -H "X-API-Key: ${PORKBUN_API_KEY}" \
        -H "X-Secret-API-Key: ${PORKBUN_SECRET_API_KEY}" "$url")" \
        || die "Porkbun request failed: ${url}"
    if [[ "$code" != "200" ]]; then
        msg="$(jq -r '.message//.error//empty' "$file" 2>/dev/null||true)"
        die "Porkbun HTTP ${code}: ${msg:-unknown}"
    fi
    jq -e . "$file" >/dev/null 2>&1 || die "Porkbun returned invalid JSON."
    status="$(jq -r '.status//empty' "$file")"
    [[ "$status" == "SUCCESS" ]] || die "Porkbun API ${status}: $(jq -r '.message//"unknown"' "$file")"
}

# ── Porkbun ────────────────────────────────────────────────

pb_fetch_domains() {
    local start=0 page=0 pf combined="${TEMP_DIR}/pb-domains-raw.json"
    printf '[]\n' > "$combined"

    while true; do
        pf="${TEMP_DIR}/pb-page-${page}.json"
        log "INFO" "Porkbun: fetching domains offset ${start}."
        pb_api_get "${PB_API_BASE}/domain/listAll?start=${start}" "$pf"

        local cnt; cnt="$(jq -r '.domains|length' "$pf")"
        jq -s '.[0]+.[1].domains' "$combined" "$pf" > "${combined}.next"
        mv -f "${combined}.next" "$combined"
        log "INFO" "Porkbun: ${cnt} domains from offset ${start}."
        (( cnt < PB_PAGE_SIZE )) && break
        start=$((start + PB_PAGE_SIZE)); page=$((page + 1))
    done
}

pb_fetch_pricing() {
    local tlds pf="${TEMP_DIR}/pb-pricing.json"

    tlds="$(jq -r '[.[].tld]|unique|join(",")' "${TEMP_DIR}/pb-domains-raw.json")"
    if [[ -z "$tlds" ]]; then
        log "WARN" "Porkbun: no TLDs for pricing."
        printf '{}' > "$pf"; return 0
    fi

    local tld_arr; tld_arr="$(printf '%s' "$tlds" | jq -R 'split(",")' -)"
    log "INFO" "Porkbun: fetching TLD pricing."

    local code
    code="$(curl -sS --location --connect-timeout 15 --max-time 60 \
        --retry 2 --retry-delay 2 --retry-all-errors \
        -o "$pf" -w '%{http_code}' \
        -H "Accept: application/json" -H "Content-Type: application/json" \
        -H "X-API-Key: ${PORKBUN_API_KEY}" \
        -H "X-Secret-API-Key: ${PORKBUN_SECRET_API_KEY}" \
        -d "{\"tlds\":${tld_arr}}" "${PB_API_BASE}/pricing/get")" || {
        log "WARN" "Porkbun pricing fetch failed."; printf '{}' > "$pf"; return 0
    }
    if [[ "$code" != "200" ]] || ! jq -e '.pricing' "$pf" >/dev/null 2>&1; then
        log "WARN" "Porkbun pricing HTTP ${code}."; printf '{}' > "$pf"; return 0
    fi
    jq '.pricing' "$pf" > "${pf}.tmp" && mv "${pf}.tmp" "$pf"
}

pb_enrich() {
    log "INFO" "Porkbun: enriching with pricing data."
    jq --slurpfile prices "${TEMP_DIR}/pb-pricing.json" '
      map(select((.status//""|ascii_upcase)=="ACTIVE"))
      | sort_by(.domain)
      | map(
          ($prices[0][.tld].renewal//null) as $rc |
          . + {
            autoRenew: (.autoRenew=="1"),
            renewal_cost: (if $rc then {amount:($rc|tonumber),currency:"USD"} else null end)
          }
        )
    ' "${TEMP_DIR}/pb-domains-raw.json" > "${TEMP_DIR}/pb-enriched.json"
}

# ── Cloudflare ──────────────────────────────────────────────

cf_fetch_zones() {
    local page=1 tp=1 pf combined="${TEMP_DIR}/cf-zones-raw.json"
    printf '[]\n' > "$combined"

    while (( page <= tp )); do
        pf="${TEMP_DIR}/cf-zones-page-${page}.json"
        log "INFO" "Cloudflare: fetching zones page ${page}."
        cf_api_get "${CF_API_BASE}/zones?account.id=${CLOUDFLARE_ACCOUNT_ID}&status=active&page=${page}&per_page=${PER_PAGE}&order=name&direction=asc" "$pf"
        tp="$(jq -r '.result_info.total_pages//1' "$pf")"
        local cnt; cnt="$(jq -r '.result|length' "$pf")"
        jq -s '.[0]+.[1].result' "$combined" "$pf" > "${combined}.next"
        mv -f "${combined}.next" "$combined"
        log "INFO" "Cloudflare: ${cnt} zones page ${page}/${tp}."
        page=$((page + 1))
    done
}

cf_dedup() {
    local pb_names="${TEMP_DIR}/pb-domain-names.txt"
    jq -r '.[].domain' "${TEMP_DIR}/pb-enriched.json" | LC_ALL=C sort -u > "$pb_names"

    log "INFO" "Dedup: removing Cloudflare zones that match Porkbun domains."

    jq --slurpfile names <(jq -R . "$pb_names" | jq -s .) '
      [.[] | select(.name as $n | ($names[0] | index($n) | not))]
    ' "${TEMP_DIR}/cf-zones-raw.json" > "${TEMP_DIR}/cf-zones-deduped.json"

    local before after
    before="$(jq -r 'length' "${TEMP_DIR}/cf-zones-raw.json")"
    after="$(jq -r 'length' "${TEMP_DIR}/cf-zones-deduped.json")"
    log "INFO" "Dedup: ${before} Cloudflare zones → ${after} after removing ${before}-${after} Porkbun-owned."
}

cf_fetch_registrar() {
    local combined="${TEMP_DIR}/cf-registrar.json" page=1 tp pf code
    printf '[]\n' > "$combined"

    pf="${TEMP_DIR}/cf-registrar-page-1.json"
    log "INFO" "Cloudflare: fetching registrar registrations."
    if ! cf_api_get_optional "${CF_REGISTRAR_API}/registrations?per_page=${PER_PAGE}&page=1" "$pf"; then
        log "WARN" "Cloudflare registrar unavailable (token needs Account:Registrar Read)."
        return 0
    fi
    tp="$(jq -r '.result_info.total_pages//1' "$pf")"
    jq -s '.[0]+.[1].result' "$combined" "$pf" > "${combined}.next"
    mv -f "${combined}.next" "$combined"
    log "INFO" "Cloudflare registrar page 1/${tp}."

    while (( page < tp )); do
        page=$((page + 1))
        pf="${TEMP_DIR}/cf-registrar-page-${page}.json"
        if ! cf_api_get_optional "${CF_REGISTRAR_API}/registrations?per_page=${PER_PAGE}&page=${page}" "$pf"; then
            log "WARN" "Cloudflare registrar page ${page} failed."
            continue
        fi
        jq -s '.[0]+.[1].result' "$combined" "$pf" > "${combined}.next"
        mv -f "${combined}.next" "$combined"
        log "INFO" "Cloudflare registrar page ${page}/${tp}."
    done
}

cf_fetch_tld_pricing() {
    local pf="${TEMP_DIR}/cf-pricing.json"
    log "INFO" "Cloudflare: fetching TLD pricing from cfdomainpricing.com."
    curl -sS --location --connect-timeout 15 --max-time 30 \
        --retry 2 --retry-delay 2 -o "$pf" "$CF_PRICING_URL" 2>/dev/null || {
        log "WARN" "Cloudflare pricing fetch failed."; printf '{}' > "$pf"; return 0
    }
    jq -e . "$pf" >/dev/null 2>&1 || { log "WARN" "Invalid pricing data."; printf '{}' > "$pf"; }
}

cf_enrich() {
    local reg="${TEMP_DIR}/cf-registrar.json" prices="${TEMP_DIR}/cf-pricing.json"
    local zones="${TEMP_DIR}/cf-zones-deduped.json" out="${TEMP_DIR}/cf-enriched.json"

    # Build registrar lookup by domain_name
    local reg_lookup="${TEMP_DIR}/cf-registrar-lookup.json"
    if [[ -s "$reg" ]] && jq -e 'length > 0' "$reg" >/dev/null 2>&1; then
        jq '[.[]|select(.domain_name)|{key:.domain_name,value:{expires_at:.expires_at,auto_renew:.auto_renew}}]|from_entries' "$reg" > "$reg_lookup"
    else
        printf '{}' > "$reg_lookup"
    fi

    log "INFO" "Cloudflare: enriching deduped zones."

    jq --slurpfile reg "$reg_lookup" --slurpfile prices "$prices" '
      sort_by(.name)
      | map({
          name,
          status,
          account: {id:.account.id, name:.account.name},
          activated_on,
          created_on,
          modified_on,
          name_servers,
          expires_at: ($reg[0][.name] | if .!=null then .expires_at else null end),
          auto_renew: ($reg[0][.name] | if .!=null then .auto_renew else null end),
          renewal_cost: (
            ($prices[0][(.name|split(".")|last)]//null) as $p |
            if $p then {amount:$p.renewal,currency:"USD"} else null end
          )
        })
    ' "$zones" > "$out"
}

# ── Merge & Output ─────────────────────────────────────────

produce_combined_json() {
    log "INFO" "Producing combined JSON."
    jq -s '
      def norm_date:
        if . == null then null
        else (tostring | sub("\\.[0-9]+Z$"; "") | sub("T"; " ") | sub("Z$"; ""))
        end;

      def norm_cf:
        {
          domain: .name,
          source: "Cloudflare",
          status: .status,
          expires_at: (.expires_at | norm_date),
          auto_renew: .auto_renew,
          renewal_cost: .renewal_cost,
          provider_meta: (
            . |
            .expires_at = (.expires_at | norm_date) |
            .activated_on = (.activated_on | norm_date) |
            .created_on = (.created_on | norm_date) |
            .modified_on = (.modified_on | norm_date)
          )
        };

      def norm_pb:
        {
          domain: .domain,
          source: "Porkbun",
          status: (.status | ascii_downcase),
          expires_at: .expireDate,
          auto_renew: .autoRenew,
          renewal_cost: .renewal_cost,
          provider_meta: .
        };

      (.[0] | map(norm_cf)) + (.[1] | map(norm_pb))
      | sort_by(.domain)
    ' "${TEMP_DIR}/cf-enriched.json" "${TEMP_DIR}/pb-enriched.json" > "$JSON_OUT"
}

produce_csv() {
    log "INFO" "Producing CSV."
    printf 'source,domain,status,expires_at,auto_renew,renewal_cost_usd\n' > "$CSV_OUT"
    jq -r '.[] | [.source,.domain,.status,(.expires_at//""),.auto_renew,(.renewal_cost.amount//"")] | @csv' "$JSON_OUT" >> "$CSV_OUT"
}

print_summary() {
    local total cf_cnt pb_cnt active_cost stopped_cost active_cnt stopped_cnt
    cf_cnt="$(jq '[.[]|select(.source=="Cloudflare")]|length' "$JSON_OUT")"
    pb_cnt="$(jq '[.[]|select(.source=="Porkbun")]|length' "$JSON_OUT")"
    total="$((cf_cnt + pb_cnt))"

    read -r active_cnt active_cost < <(jq -r '[.[]|select(.auto_renew==true)]|"\(length) \(([.[].renewal_cost.amount//0]|add)|.*100|round|./100)"' "$JSON_OUT")
    read -r stopped_cnt stopped_cost < <(jq -r '[.[]|select(.auto_renew!=true)]|"\(length) \(([.[].renewal_cost.amount//0]|add)|.*100|round|./100)"' "$JSON_OUT")

    cat <<EOF

═══════════════════════════════════════════════════════════
  Domain Portfolio Summary
═══════════════════════════════════════════════════════════
  Source       Domains
  ─────────    ───────
  Porkbun      ${pb_cnt}
  Cloudflare   ${cf_cnt}
  ─────────    ───────
  Total        ${total}
═══════════════════════════════════════════════════════════
  Status       Domains   Annual Cost
  ─────────    ───────   ───────────
  Active       ${active_cnt}        \$ ${active_cost}
  Stopped      ${stopped_cnt}        \$ ${stopped_cost}
  ─────────    ───────   ───────────
  Total        ${total}        \$ $(awk "BEGIN {printf \"%.2f\", ${active_cost}+${stopped_cost}}")
═══════════════════════════════════════════════════════════

EOF
    log "INFO" "JSON output: ${JSON_OUT}"
    log "INFO" "CSV output:  ${CSV_OUT}"
}

# ── Main ───────────────────────────────────────────────────

main() {
    mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$(dirname -- "$LOCK_FILE")"

    RUN_LOG="${LOG_DIR}/${SCRIPT_NAME}-${RUN_TIMESTAMP}.log"
    : > "$RUN_LOG"; chmod 600 "$RUN_LOG"

    exec 9>"$LOCK_FILE"; flock -n 9 || die "Another run is active."

    trap cleanup EXIT INT TERM

    require_command curl; require_command jq; require_command flock; require_command install

    load_env
    CF_REGISTRAR_API="${CF_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/registrar"

    TEMP_DIR="$(mktemp -d "${OUTPUT_DIR}/.${SCRIPT_NAME}.XXXXXX")"
    prune_logs

    log "INFO" "=== domain-portfolio run started ==="

    # 1. Porkbun (purchase source — priority for dedup)
    log "INFO" "--- Porkbun ---"
    pb_fetch_domains
    pb_fetch_pricing
    pb_enrich

    # 2. Cloudflare zones
    log "INFO" "--- Cloudflare ---"
    cf_fetch_zones

    # 3. Dedup: remove Cloudflare DNS zones that match Porkbun domains
    cf_dedup

    # 4. Cloudflare registrar (expiry + auto-renew) & pricing
    cf_fetch_registrar
    cf_fetch_tld_pricing
    cf_enrich

    # 5. Merge & output
    produce_combined_json
    produce_csv
    print_summary

    log "INFO" "=== domain-portfolio run complete ==="
}

main "$@"
