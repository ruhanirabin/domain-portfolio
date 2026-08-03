# AGENTS.md — Domain Portfolio

## Project Purpose

This project consolidates domain portfolios from Porkbun and Cloudflare into a deduplicated, enriched report with auto-renew status, expiration dates, and annual renewal costs. It produces a Google Sheets-compatible CSV for portfolio management.

## Architecture

Single-file bash script (`domain-portfolio.sh`) with no external dependencies beyond standard Unix tools. Designed to be OSS-ready: one script, one `.env` file, one command.

### Execution Flow

```
domain-portfolio.sh
  ├── load_env()        — reads .env or checks exported vars
  ├── Porkbun (first — purchase authority)
  │   ├── pb_fetch_domains()   — GET /domain/listAll (paginated)
  │   ├── pb_fetch_pricing()   — POST /pricing/get (TLD renewal costs)
  │   └── pb_enrich()          — jq: merge domains + pricing
  ├── Cloudflare
  │   ├── cf_fetch_zones()     — GET /zones (paginated, active only)
  │   ├── cf_dedup()           — jq: remove zones matching Porkbun domains
  │   ├── cf_fetch_registrar() — GET /registrar/registrations (paginated)
  │   ├── cf_fetch_tld_pricing() — curl: cfdomainpricing.com/prices.json
  │   └── cf_enrich()          — jq: merge zones+registrar+pricing
  ├── Merge
  │   ├── produce_combined_json() — jq: normalize schema, merge sources
  │   └── produce_csv()           — jq: flatten to CSV
  └── print_summary()           — terminal output with counts and costs
```

### Key Design Decisions

1. **Porkbun first**: Porkbun domains are the purchase authority. Cloudflare zones that match Porkbun domain names are treated as duplicates and removed.
2. **Single .env file**: Both Cloudflare and Porkbun credentials in one file.
3. **Best-effort enrichment**: Missing API permissions or failed pricing fetches produce `null` values — the script never dies on enrichment failure.
4. **Lock file**: `flock`-based lock prevents concurrent runs.
5. **Temp directory**: All intermediate files in `$TMPDIR`-style dir under `output/`, cleaned up on exit via trap.

## API Endpoints Used

### Porkbun (base: `https://api.porkbun.com/api/json/v3`)

| Endpoint | Method | Auth | Purpose |
|---|---|---|---|
| `/domain/listAll?start=N` | GET | Headers | List domains (paginated, 1000/page) |
| `/pricing/get` | POST | Headers | TLD pricing (body: `{"tlds":[...]}`) |

Response fields from `listAll`:
- `domain`, `status`, `tld`, `createDate`, `expireDate`, `securityLock`
- `whoisPrivacy`, `autoRenew` ("1"/"0"), `apiAccess`, `notLocal`

Response from `pricing/get`:
```json
{"status":"SUCCESS","pricing":{"com":{"registration":"11.08","renewal":"11.08","transfer":"11.08","coupons":[]}}}
```

### Cloudflare (base: `https://api.cloudflare.com/client/v4`)

| Endpoint | Auth | Purpose |
|---|---|---|
| `/zones?account.id=X&status=active&page=N&per_page=50` | Bearer | List DNS zones |
| `/accounts/X/registrar/registrations?page=N&per_page=50` | Bearer | List registered domains |

Token permissions needed:
- `Zone:Zone — Read` (zones list)
- `Account:Registrar — Read` (registrar data; optional — script continues without it)

Response from `registrations`:
- `domain_name`, `expires_at`, `auto_renew`, `created_at`, `locked`, `privacy_mode`, `status`

### External (no auth)

| URL | Purpose |
|---|---|
| `https://cfdomainpricing.com/prices.json` | Cloudflare TLD renewal costs |

Response: `{"com":{"registration":11.08,"renewal":11.08,"updatedAt":"2026-05-17"},...}`

## Output Schema

### `output/domains.json`

Array of objects, 7 fields per entry:

```json
{
  "domain": "example.com",           // FQDN
  "source": "Cloudflare|Porkbun",    // purchase source
  "status": "active|expired|...",    // lowercase
  "expires_at": "2027-01-01 00:00:00", // YYYY-MM-DD HH:MM:SS (or null)
  "auto_renew": true|false,          // boolean (or null if unknown)
  "renewal_cost": {                  // or null
    "amount": 11.08,                 // USD as number
    "currency": "USD"
  },
  "provider_meta": { }               // raw provider response
}
```

### `output/domains.csv`

6 columns: `source`, `domain`, `status`, `expires_at`, `auto_renew`, `renewal_cost_usd`

## File Structure

```
.
├── .env.example              # Template — copy to .env
├── .gitignore                # Excludes .env, output/, logs/
├── LICENSE                   # MIT
├── README.md                 # User-facing documentation
├── CHANGELOG.md              # Version history
├── AGENTS.md                 # This file
├── domain-portfolio.sh       # Master script (sole entry point)
├── output/
│   ├── .gitkeep
│   ├── domains.json          # Generated
│   └── domains.csv           # Generated
└── logs/                     # Generated, retained 7 days
```

## Development Conventions

### Commit Style
This project follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). The CHANGELOG is generated from commit messages organized by type.

Common scopes for this repo:
- `feat(cloudflare)` / `feat(porkbun)` — provider-specific features
- `feat(output)` — JSON/CSV output changes
- `feat(pricing)` — pricing API integration
- `fix(jq)` — jq filter bugs
- `chore` — tooling, docs, cleanup

### Bash Style
- `set -Eeuo pipefail` at top
- `umask 077` for secure file creation
- Functions prefixed with provider: `pb_*`, `cf_*`
- All intermediate work in `${TEMP_DIR}` (created under `output/`)
- `readonly` for configuration constants

### Error Handling
- `die()` for fatal errors (API auth failure, missing credentials)
- `log "WARN"` for non-fatal issues (pricing unavailable, registrar permission missing)
- `trap cleanup EXIT INT TERM` ensures temp directory deletion
- `flock` prevents concurrent runs with clear error message

### jq Patterns
- `--slurpfile` for passing auxiliary data files into jq filters
- `from_entries` for building lookup maps from arrays
- `norm_date` function standardizes all date formats
- `if . != null then ... else null end` for null-safe field extraction (avoids `//` falsy issue with `false`)

## Common Tasks

### Adding a new data field to the output

1. Add the field to the `norm_cf` and `norm_pb` jq objects in `produce_combined_json()`
2. Update the CSV columns in `produce_csv()`
3. Update `README.md` schema docs
4. Update this `AGENTS.md` schema docs

### Adding a new API endpoint

1. Add a new `*_fetch_*()` function following existing patterns (see `pb_fetch_pricing` for a simple example, `cf_fetch_registrar` for paginated)
2. Add an enrichment step in the main flow
3. Update the jq enrichment filter in the corresponding `_enrich()` function
4. Update README.md architecture diagram and API table

### Debugging

1. Run with `set -x` for trace output
2. Temp directory is under `output/.domain-portfolio.*` — inspect intermediates
3. Log files in `logs/domain-portfolio-*.log` — retained 7 days
4. Pricing data can be tested independently:
   - Porkbun: `curl -X POST https://api.porkbun.com/api/json/v3/pricing/get -H 'Content-Type: application/json' -d '{"tlds":["com"]}'`
   - Cloudflare: `curl https://cfdomainpricing.com/prices.json | jq '.com'`

## Testing

Manual testing workflow:
```bash
# Syntax check
bash -n domain-portfolio.sh

# Run (requires valid .env)
./domain-portfolio.sh

# Verify output
jq 'length' output/domains.json
jq '.[] | select(.source=="Cloudflare") | length' output/domains.json
jq '.[] | select(.source=="Porkbun") | length' output/domains.json
jq '[.[] | select(.expires_at == null)] | map(.domain)' output/domains.json
```

No automated test suite exists — the script depends on live API calls.
