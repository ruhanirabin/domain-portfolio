# Domain Portfolio

Consolidate your domain portfolio from Porkbun and Cloudflare into a single, deduplicated report — with auto-renew status, expiration dates, and annual renewal costs.

One script. One `.env` file. One CSV for Google Sheets.

## What It Does

1. **Fetches all domains from Porkbun** via the Porkbun API — the purchase source takes priority.
2. **Fetches all active DNS zones from Cloudflare** via the Cloudflare API.
3. **Deduplicates**: removes Cloudflare zones that use DNS but are owned through Porkbun. Porkbun always wins.
4. **Enriches** each domain with:
   - `expires_at` — expiration date (standardized to `YYYY-MM-DD HH:MM:SS`)
   - `auto_renew` — whether auto-renewal is enabled (boolean)
   - `renewal_cost` — annual renewal cost in USD from TLD pricing APIs
5. **Outputs**:
   - `output/domains.json` — full deduplicated enriched JSON
   - `output/domains.csv` — ready for import into Google Sheets

## Output Format

### CSV (for Google Sheets)

| Column | Type | Description |
|---|---|---|
| `source` | Text | `Cloudflare` or `Porkbun` |
| `domain` | Text | Fully qualified domain name |
| `status` | Text | `active`, `expired`, etc. |
| `expires_at` | Date | `YYYY-MM-DD HH:MM:SS` (auto-detected by Sheets) |
| `auto_renew` | Boolean | `true` / `false` |
| `renewal_cost_usd` | Number | Annual USD renewal cost (or empty) |

In Google Sheets:
- `=SUMIF(E2:E, TRUE, F2:F)` → total annual cost for **active** (renewing) domains
- `=SUMIF(E2:E, "<>TRUE", F2:F)` → total saved by **stopped** domains

### JSON

```json
{
  "domain": "example.com",
  "source": "Porkbun",
  "status": "active",
  "expires_at": "2027-07-25 11:25:11",
  "auto_renew": true,
  "renewal_cost": {
    "amount": 11.08,
    "currency": "USD"
  },
  "provider_meta": { /* raw provider data */ }
}
```

## Prerequisites

- **bash** 4+, **curl**, **jq**, **flock** (util-linux), **install** (coreutils)
- Cloudflare account with an API token
- Porkbun account with API keys

## Quick Start

```bash
# 1. Clone
git clone https://github.com/your-org/domain-portfolio.git
cd domain-portfolio

# 2. Configure credentials
cp .env.example .env
chmod 600 .env
# Edit .env with your Cloudflare and Porkbun credentials

# 3. Run
./domain-portfolio.sh
```

## Configuration

### `.env` file (recommended)

```bash
# Cloudflare — create token at https://dash.cloudflare.com/profile/api-tokens
# Required permissions: Zone:Zone Read, Account:Registrar Read
CLOUDFLARE_ACCOUNT_ID="your-32-character-account-id"
CLOUDFLARE_API_TOKEN="your-api-token"

# Porkbun — create keys at https://porkbun.com/account/api
PORKBUN_API_KEY="pk1_..."
PORKBUN_SECRET_API_KEY="sk1_..."
```

### Environment variables (alternative)

Export the same variables before running:

```bash
export CLOUDFLARE_ACCOUNT_ID="..." CLOUDFLARE_API_TOKEN="..."
export PORKBUN_API_KEY="..." PORKBUN_SECRET_API_KEY="..."
./domain-portfolio.sh
```

### Optional overrides

| Variable | Default | Description |
|---|---|---|
| `ENV_FILE` | `./.env` | Path to credential file |
| `OUTPUT_DIR` | `./output` | Where JSON and CSV are written |
| `LOG_DIR` | `./logs` | Log files (retained 7 days) |
| `LOCK_FILE` | `./.domain-portfolio.lock` | Prevents concurrent runs |

## Architecture

```
domain-portfolio.sh
    │
    ├─ 1. Porkbun API (first — purchase authority)
    │     ├─ /domain/listAll      → all domains + expireDate + autoRenew
    │     └─ /pricing/get         → TLD renewal costs
    │
    ├─ 2. Cloudflare API
    │     ├─ /zones               → all DNS zones
    │     ├─ DEDUP                → remove zones owned via Porkbun
    │     ├─ /registrar/registrations → expires_at + auto_renew
    │     └─ cfdomainpricing.com  → TLD renewal costs
    │
    └─ 3. Merge → output/domains.json + output/domains.csv
```

### Deduplication Logic

- Porkbun fetches first (purchase source).
- Cloudflare zones that match Porkbun domain names are **removed**.
- Remaining Cloudflare zones are treated as Cloudflare-purchased.
- If a Cloudflare zone's domain is not registered through Cloudflare Registrar, `expires_at` and `auto_renew` will be `null`.

### Pricing Sources

| Provider | Source | Auth |
|---|---|---|
| Porkbun | Official `/pricing/get` API | API keys required |
| Cloudflare | `cfdomainpricing.com/prices.json` (public) | None |

Cloudflare does not expose TLD renewal pricing for already-registered domains via their API. The script uses the public `cfdomainpricing.com` dataset as a supplement. This is not an official Cloudflare API.

## Error Handling

- **Registrar API unavailable** (missing permissions): logged as warning, `expires_at` / `auto_renew` set to `null`.
- **Pricing fetch fails**: logged as warning, `renewal_cost` set to `null`.
- **Concurrent runs**: prevented by `flock`-based lock file.
- **Temporary files**: cleaned up automatically on exit (success or failure).

## Contributing

Pull requests welcome. This project follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) for commit messages. Common scopes: `cloudflare`, `porkbun`, `output`, `pricing`, `jq`.

See [AGENTS.md](AGENTS.md) for the full architecture, API reference, and development conventions.

## License

MIT — see [LICENSE](LICENSE).

## About the Author

[Ruhani Rabin](https://www.ruhanirabin.com) is an independent product and technology advisor who has developed software professionally since 1997 and led product work since 2010. He helps SaaS and WordPress teams fix what is slow, confusing, repetitive, or unnecessarily complex — from website performance and workflow automation to product strategy and technology decisions.
