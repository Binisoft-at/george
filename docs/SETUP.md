# George – setup

The account steps for George, from the Binisoft handbook's
[SETUP_CHECKLIST.md](https://github.com/Binisoft-at/binisoft-handbook/blob/main/SETUP_CHECKLIST.md) (private)
with George's values. Claude turns them into a numbered claude.ai checklist and ticks steps off.

| | |
|---|---|
| App Store name | **George - Your Gym Buddy** |
| Home-screen name | George |
| GitHub repo | `Binisoft-at/george` |
| Bundle ID (iOS + macOS) = SKU | `at.binisoft.george` |
| Watch app | `at.binisoft.george.watchkitapp` (ships inside the iOS app) |
| Own iCloud container | `iCloud.at.binisoft.george` |
| Shared iCloud container / App Group | `iCloud.at.binisoft.shared` / `group.at.binisoft.shared` (exist – only tick them) |
| Shared keychain group | `$(AppIdentifierPrefix)at.binisoft.shared` (no portal step) |
| Capabilities | iOS + Mac: iCloud (CloudKit, both containers), App Groups, Push Notifications, HealthKit (iOS) · Watch: HealthKit, App Groups |
| TestFlight group | `Binisoft Team`, automatic distribution |
| App Store Connect app id | 6828760060 |

All identifiers are defined in [`Config/Base.xcconfig`](../Config/Base.xcconfig).

## Steps (done for George)

1. **GitHub** – repo `Binisoft-at/george` (created private; going public: [PUBLISHING.md](PUBLISHING.md)).
2. **Portal** – iCloud container `iCloud.at.binisoft.george`; App IDs `at.binisoft.george` and
   `at.binisoft.george.watchkitapp` with the capabilities above.
3. **App Store Connect** – "George - Your Gym Buddy" (iOS + macOS), SKU `at.binisoft.george`;
   TestFlight → Internal Testing → `Binisoft Team`, automatic distribution.
4. **Repository secrets** – `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`,
   `CLOUDKIT_MANAGEMENT_TOKEN`.
5. **CloudKit** – Actions → CloudKit schema → Run workflow; then CloudKit Console →
   `iCloud.at.binisoft.george` → Development → **Deploy Schema Changes** → Deploy.
   Until this is done, TestFlight builds keep data on each device (Settings shows "Not syncing").
6. **TestFlight** – a commit with `[testflight]`, a `v*` tag, or Actions → TestFlight → Run workflow.
   Build number = workflow run number; builds show up in TestFlight 5–30 minutes after upload
   (Actions → App Store Connect status).

## After a model change

`cloudkit/schema.ckdb` → CloudKit schema workflow → Deploy Schema Changes to Production → TestFlight.
New fields are optional or have a default; never rename or remove a synced field.

## Local development

```bash
make check                                             # no Mac needed: Core tests + syntax check
cp Config/Local.xcconfig.example Config/Local.xcconfig # set DEVELOPMENT_TEAM (Mac, signed runs)
make open                                              # generates George.xcodeproj with XcodeGen
```

CI results without the Actions logs: `git fetch origin ci-output && git show origin/ci-output:ci/status.txt`
(also `ci-testflight`, `ci-cloudkit`; screenshots under `ci/shots/` after a `[screenshots]` run).
