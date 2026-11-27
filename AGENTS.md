# Repository Rules for AI Agents

This repository (`zev-scoop`) is a personal Windows Scoop bucket whose default branch is `dev`. Follow these rules strictly on every task.

## 1. Branch & Pull Request Workflow

- **Never commit or push directly to `dev` (or `main`/`master`).**
- Always branch from up-to-date `dev` using a descriptive branch name:
  - `feat/<topic>` for new packages or features
  - `fix/<topic>` for bug fixes
  - `docs/<topic>` for documentation updates
  - `chore/<topic>` for maintenance or CI updates
- Open a Pull Request targeting `dev` with:
  - Summary of changes and official upstream evidence (for packages)
  - Exact local verification commands and results (never claim checks that were not run)
- **Never auto-merge Pull Requests.** All PRs require passing CI checks and manual human review.

## 2. Package & Security Rules

- Only use verified **official** upstream download sources, release APIs, or official channel manifests.
- Never copy manifests or URLs from third-party Scoop buckets and represent them as official.
- Never execute unreviewed remote installation scripts inside a Scoop manifest.
- Verify official SHA256 checksums, Authenticode signatures (when available), archive structure, architecture support, license terms, and self-update isolation before adding or updating a manifest.
- Every supported package must have:
  - Manifest under `bucket/<package>.json` conforming to Scoop `schema.json`
  - Dedicated package doc under `docs/packages/<package>.md`
  - Validation rules in `scripts/validate-manifest.py`
  - Unit test coverage in `tests/test_manifest.py`
  - Update adapter + workflow coverage (`.github/workflows/update-*.yml`) and lifecycle CI coverage (`.github/workflows/test-*.yml`)

## 3. Testing & Local Environment Rules

- Always run local syntax, manifest validation (`python scripts/validate-manifest.py --all --check-url`), Scoop schema checks, and unit tests (`python -m unittest discover -s tests -v`) before pushing.
- Do **not** run full Scoop `Install`/`Upgrade` lifecycle tests that create user shortcuts or caches on the maintainer's daily Windows machine unless explicitly requested; run full Windows lifecycle checks on GitHub-hosted runners via Pull Requests.
