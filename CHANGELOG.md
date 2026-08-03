# Changelog

All notable changes to this project. This project adheres to
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).

## [1.0.0] — 2026-08-03

### Added
- `feat`: single master script (`domain-portfolio.sh`) replacing three standalone scripts
- `feat(env)!`: unified `.env` with both Cloudflare and Porkbun credentials (replaces per-provider `.env` files)
- `feat(dedup)`: Porkbun-first deduplication — Cloudflare zones owned via Porkbun are removed at merge
- `feat(registrar)`: domain expiration date enrichment via Cloudflare Registrar API (`expires_at`)
- `feat(registrar)`: auto-renew boolean from both providers (Porkbun string `"1"`/`"0"` → boolean)
- `feat(pricing)`: Porkbun `/pricing/get` TLD renewal cost enrichment
- `feat(pricing)`: Cloudflare TLD renewal cost via `cfdomainpricing.com` public dataset
- `feat(output)`: combined `output/domains.json` (7 top-level fields, normalized schema)
- `feat(output)`: combined `output/domains.csv` with Google Sheets-compatible date cells
- `feat(output)`: terminal summary with active vs. stopped domain counts and annual costs
- `feat(csv)`: `SUMIF`-ready CSV for Google Sheets portfolio management

### Changed
- `refactor`: all provider logic merged into single script with `pb_*` / `cf_*` function prefix convention
- `style`: date fields normalized to `YYYY-MM-DD HH:MM:SS` (Google Sheets auto-detects as Date)
- `style`: `autoRenew` converted from Porkbun string to boolean in output
- `style`: all date fields in `provider_meta` normalized (removes `.µsZ` suffix, `T` separator)

### Removed
- `chore`: `cloudflare-active-zones-portable.sh` (replaced by master script)
- `chore`: `porkbun-active-domains.sh` (replaced by master script)
- `chore`: `consolidate-to-csv.sh` (merged into master script)
- `chore`: per-provider `.env` files (replaced by unified `.env`)
- `chore`: per-provider output files (`cloudflare-zones.*`, `porkbun-domains.*`)

### Fixed
- `fix(jq)`: null-safe field extraction using `if . != null then ... else null end` instead of `//` (which treats `false` as falsy)
- `fix(cleanup)`: lock file and temp directory now cleaned on exit (success or failure)

## [0.7.0] — 2026-08-03

### Added
- `feat(registrar)`: Cloudflare registrar registrations API for `expires_at` and `auto_renew`
- `feat(pricing)`: Cloudflare TLD pricing from `cfdomainpricing.com`
- `feat(pricing)`: Porkbun `/pricing/get` API for `renewal_cost`
- `feat(porkbun)`: `autoRenew` boolean conversion in output

### Changed
- `refactor`: output files renamed to `cloudflare-zones.*` and `porkbun-domains.*`

## [0.6.0] — 2026-07-26

### Added
- `feat(cloudflare)`: initial Cloudflare zones script with pagination, locking, logging
- `feat(porkbun)`: initial Porkbun domains script with pagination, locking, logging
- `feat(config)`: portable credential, output, and log path configuration via env vars
