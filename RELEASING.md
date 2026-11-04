# Releasing

`nativebind` and `nativebind_generator` are released together, with one
version number (the generator writes code for the runtime of the same
version). A release is a `vX.Y.Z` tag: pushing it runs
[`release.yml`](.github/workflows/release.yml), which

1. checks that every recorded version equals the tag and that `CHANGELOG.md`
   has its section (`dart tool/release.dart check X.Y.Z`),
2. runs the full CI on the tagged commit,
3. publishes both packages to pub.dev through
   [automated publishing](https://dart.dev/tools/pub/automated-publishing)
   (no stored credentials; GitHub signs a short-lived token), after a
   maintainer approves the `pub.dev` environment,
4. creates the GitHub release, with the changelog section as its notes.

Versions follow [Semantic Versioning](https://semver.org/); before 1.0, a
minor version (0.2.0 → 0.3.0) may break the API and a patch version may not.

## Every release

1. Make sure `CHANGELOG.md` has an `## Unreleased` section listing every
   user-facing change (contributors add entries with their changes).
2. On a branch, prepare the release, review the diff and open a PR:

   ```sh
   dart tool/release.dart prepare 0.3.0
   ```

   This sets the version in both pubspecs, the native `CMakeLists.txt` and the
   example's dependencies, turns `## Unreleased` into `## 0.3.0 - <date>`, and
   adds an entry to each package's `CHANGELOG.md`.
3. Merge the PR once CI is green (CI also runs `pub publish --dry-run` for
   both packages).
4. Tag the merge commit on `main` and push the tag:

   ```sh
   git checkout main && git pull
   git tag -a v0.3.0 -m "nativebind 0.3.0"
   git push origin v0.3.0
   ```

   Push the tag yourself: tags pushed by another workflow with the default
   token do not start workflows.
5. Approve the `pub.dev` deployment in the run's page on GitHub Actions.

A failed run can be rerun from the Actions page: a package version already on
pub.dev is skipped, so a rerun picks up where the last one stopped. A version
on pub.dev cannot be replaced; fix forward with a patch release (a broken
version can be [retracted](https://dart.dev/tools/pub/publishing#retract)).

To try the pipeline without publishing, run the workflow by hand (Actions →
Release → Run workflow, or `gh workflow run release.yml --ref <branch>`): it
runs the version check and CI, including `pub publish --dry-run` for both
packages, and stops there.

## One-time setup

pub.dev only enables automated publishing for a package that already exists,
so the first version of each package is published by hand.

1. **First publish.** After the release PR for the first version is merged,
   from a clean checkout of `main`, signed in to pub.dev in the browser:

   ```sh
   (cd packages/nativebind_generator && dart pub publish)
   (cd packages/nativebind && flutter pub publish)
   ```

   Consider a [verified publisher](https://dart.dev/tools/pub/verified-publishers)
   (a domain you own) and transfer both packages to it; pub.dev then shows
   who publishes them.
2. **Enable automated publishing**, on pub.dev, for each package (Admin →
   Automated publishing → GitHub Actions):
   - repository: `trevortomlin/nativebind`
   - tag pattern: `v{{version}}`
   - require GitHub Actions environment: `pub.dev`
3. **Create the environment** on GitHub (Settings → Environments → New
   environment `pub.dev`), with yourself as a required reviewer and, under
   deployment branches and tags, only tags matching `v*`.
4. **Tag the first release** (step 4 above). Its run skips publishing (the
   versions are already on pub.dev) and creates the GitHub release.
