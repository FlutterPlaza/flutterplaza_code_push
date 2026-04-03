## 0.1.2

- fix: safe type handling for server responses (prevents crashes from malformed data)
- fix: broad exception catch on all platform channel calls

## 0.1.1

- fix: license updated to BSD 3-Clause (was incorrectly MIT)
- fix: README license reference corrected
- add: `.pubignore` to exclude build artifacts from pub.dev archive
- add: `topics` and `issue_tracker` to pubspec.yaml for discoverability

## 0.1.0

- Initial release
- `CodePush.checkForUpdate()` — check server for available patches
- `CodePush.downloadAndApply()` — download and install a patch (with progress callback)
- `CodePush.currentPatch` — get info about the active patch
- `CodePush.isPatched` — check if running with a patch
- `CodePush.rollback()` — remove the active patch
- `CodePush.installPatch()` — install a patch from raw bytes
- `CodePush.releaseVersion` — get the baseline release version
- `CodePush.cleanupOldPatches()` — free disk space
- `CodePush.checkForUpdatePeriodically()` — periodic background checks
- `CodePush.patchCount` — number of stored patches
