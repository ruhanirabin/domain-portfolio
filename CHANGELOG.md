# Changelog

All notable changes to this project. This project adheres to
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).

## [1.1.0] — 2026-08-03

### Added
- `feat(deps)`: automated dependency check for Debian/Ubuntu — offers interactive `apt-get` install of missing `curl`/`jq` packages, prints exact install command in non-interactive mode
- `feat(security)`: credential format validation — `CLOUDFLARE_API_TOKEN` (20+ alphanumeric), `PORKBUN_API_KEY` (`pk1_` prefix), `PORKBUN_SECRET_API_KEY` (`sk1_` prefix)
- `docs`: About the Author section in README with bio and website link

### Fixed
- `fix(dedup)`: deduplication now reads from raw domains JSON instead of enriched (ACTIVE-only) output — inactive Porkbun domains no longer leak into Cloudflare results
- `fix(cleanup)`: trap handler moved before lock-acquisition `die()` call in `main()` — ensures temp directory and lock file are cleaned on early failures

### Changed
- `docs`: author references updated to "Ruhani Rabin" with website URL across LICENSE, script header, and README
- `docs`: documented ACTIVE-only output filter in README Deduplication Logic and inline script comment
- `docs`: README prerequisites rewritten for Debian 12+ / Ubuntu 22.04+ with auto-install behavior

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
