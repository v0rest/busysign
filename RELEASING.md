# Releasing BusySign

A release is a tag `vX.Y.Z` on `main`. The `release` workflow runs CI for the tag on macOS 15, 26 and 27, checks the tag
and then publishes a GitHub Release with the source tarball `busysign-X.Y.Z.tar.gz` and its `.sha256` file. The
Homebrew tap builds the app from that tarball.

1. Branch off an up-to-date `main`.

   ```sh
   git switch main && git pull --ff-only
   git switch -c release-X.Y.Z
   ```

2. Set the version. The script writes `VERSION` and `Version.current` in `Sources/BusySignCore/Version.swift`, which
   have to match.

   ```sh
   scripts/set-version.sh X.Y.Z
   git commit -am "chore: release X.Y.Z"
   ```

3. Push the branch, open a pull request and merge it once `ci-ok` is green.

4. Tag the merged commit on `main` and push the tag.

   ```sh
   git switch main && git pull --ff-only
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

5. Watch the `release` run in the Actions tab or with `gh run watch`. It stops before anything is published when CI
   fails, when the tag isn't `v` + `VERSION`, when `VERSION` and `Version.current` differ or when the tagged commit
   isn't on `main`.

6. Once the release is published, start the tap's `bump` so the formula picks it up right away. Enable it first:
   GitHub turns off a public repo's scheduled workflows after 60 days without activity, and a disabled workflow
   can't be started.

   ```sh
   gh workflow enable bump.yml -R v0rest/homebrew-tap
   gh workflow run bump.yml -R v0rest/homebrew-tap
   ```

   While the tap has had activity in the last 60 days, `bump` also runs once a day and finds the latest release by
   itself. It tests the formula on macOS 15, 26 and 27 before it commits it to the tap.

A published release is never changed, its tag and assets are immutable. A defect found after publishing is fixed in the
next patch version, released the same way. The same goes for a tag whose run stopped because the tag was wrong: `v*`
tags can't be moved or deleted, so the fix takes the next patch version. A run that failed for a flaky reason can be
re-run from the Actions tab.
