# Making the George repository public

Follows the handbook's SETUP_CHECKLIST 7 (v1.1). Public repos run GitHub Actions – including the
Mac builds – for free; the code becomes readable by everyone.

## What becomes public – and what doesn't

| Public | Stays private |
|---|---|
| Code, docs, exercise data, icon, sample CSV | Repository secrets (API key, CloudKit token) – never readable, not even for collaborators |
| CI logs, artifacts and the `ci-*` branches (screenshots use demo data) | App Store Connect, the Developer account, TestFlight testers |
| Identifiers (bundle ID, iCloud container, App Store app id) – these are in every shipped app anyway | Users' data – it lives in their own iCloud and Apple Health, never in this repo |
| `Vendor/BinisoftKit` and `scripts/ci` (copies from the private handbook) | The handbook repository itself |
| Commit history (authors: "Claude", "Binisoft CI"; early commits contain the old bundle ID prefix `com.erblinkastrati`) | |

## Done (Claude, 2026-11-08)

- Audit of all files and the full history of every branch: no keys, certificates, tokens or private
  workout data. Exercise data is public domain (free-exercise-db) or original.
- Handbook v1.1 (synced): saved CI logs are redacted (API key ID, issuer ID, CloudKit token → `***`;
  the old archive logs contained the key ID and issuer ID), the certificate list counts instead of
  naming team members and other projects (the old `asc/status.txt` named them), workflows run
  read-only except their publish jobs, fork pull requests don't publish.
- `LICENSE` (all rights reserved, source readable), `THIRD_PARTY_NOTICES.md`, `SECURITY.md`, README
  section "Status, privacy, licence".
- Not done (needs the owner – deleting is blocked for Claude here): the old `ci-*` branches and
  workflow runs were made **before** the redaction. `ci-output/asc/status.txt` names team members and
  other projects' pass IDs; the archive logs on `ci-testflight` and in the TestFlight runs' artifacts
  contain the API key ID and issuer ID (not usable without the private key, but not for the public).
  → Owner checklist 3 and 4.

## Owner checklist

1. **Decide the licence.** Default: all rights reserved (people can read, not reuse). Alternative: MIT
   (anyone may reuse, also commercially) – then replace `LICENSE`.
2. **Decide the history.** Keep it (recommended – nothing sensitive, only the old bundle prefix with
   your name), or ask Claude for a fresh single-commit history before going public.
3. **Delete the old CI branches**: <https://github.com/Binisoft-at/george/branches> → `ci-output`,
   `ci-testflight`, `ci-cloudkit` → 🗑 each. The next CI, TestFlight and CloudKit runs recreate them
   with the cleaned-up output.
4. **Delete the old workflow runs** (logs + artifacts): <https://github.com/Binisoft-at/george/actions>
   → open each run → ⋯ (top right) → **Delete workflow run** – or once in a terminal with `gh` (below).
5. **Billing.** Fix the failed payment / spending limit:
   <https://github.com/organizations/Binisoft-at/settings/billing>. Public repos don't use paid
   minutes, but a blocked account can stop all Actions.
6. **Settings → Actions → General** (<https://github.com/Binisoft-at/george/settings/actions>):
   - *Fork pull request workflows from outside collaborators* → **Require approval for all outside
     collaborators**
   - *Workflow permissions* → **Read repository contents and packages permissions** → Save
7. **Settings → Advanced Security** (<https://github.com/Binisoft-at/george/settings/security_analysis>):
   **Private vulnerability reporting**, **Dependabot alerts**, **Secret scanning** and **Push
   protection** → Enable (secret scanning appears once the repo is public).
8. **Settings → Rules → Rulesets** (<https://github.com/Binisoft-at/george/settings/rules>):
   - *New branch ruleset* "main": Enforcement **Active**, target **Default branch**, rules **Restrict
     deletions** and **Block force pushes** → Create
   - *New tag ruleset* "release tags": target pattern `v*`, rules **Restrict creations**, bypass list
     **Repository admin** → Create (a `v*` tag uploads to TestFlight)
9. **Settings → General → Danger Zone → Change repository visibility → Change to public**
   (<https://github.com/Binisoft-at/george/settings>). Confirm with the repo name.
10. **Check as a stranger**: open <https://github.com/Binisoft-at/george> in a private browser window;
   after the next CI run, open its log and the `ci-output` branch.
11. **Tell Claude "public"** – Claude reruns CI with screenshots, checks the outputs once more and
   updates this file.

## Cleanup commands (for later, or for the other apps)

```bash
# Delete every workflow run (logs + artifacts) of a repo
gh run list --repo Binisoft-at/<app> --limit 1000 --json databaseId --jq '.[].databaseId' \
  | xargs -n1 gh run delete --repo Binisoft-at/<app>
# Delete the CI output branches (the next runs recreate them)
git push origin --delete ci-output ci-testflight ci-cloudkit
```
