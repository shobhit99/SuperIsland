# Release checklist

This checklist separates local contributor builds from signed maintainer releases. Local builds can stay unsigned or development-signed. Public releases should be Developer ID signed, notarized, stapled, and verified before publishing.

## Local unsigned DMG

```bash
./scripts/build-dmg.sh
```

The local script builds a universal Release app, bundles a universal Node.js runtime, creates `build/SuperIsland.dmg`, and signs with a local development certificate only when one is available.

To check the script without building:

```bash
./scripts/build-dmg.sh --dry-run
```

## Signed release DMG

Create `.env` from `.env.template` and fill in:

```bash
APPLE_ID=you@example.com
APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
TEAM_ID=XXXXXXXXXX
SIGNING_IDENTITY=Developer ID Application: Your Name (TEAMID)
```

Then run:

```bash
./scripts/build-and-release.sh
```

To validate commands and credentials without cleaning or building:

```bash
./scripts/build-and-release.sh --dry-run
```

The release script archives a universal app, bundles a universal Node.js runtime, signs the app and DMG, submits the DMG for notarization, staples the ticket, and verifies the final DMG.

## Universal binary verification

After building an app bundle, verify the app binary and bundled runtime:

```bash
./scripts/verify-universal-build.sh build/SuperIsland.app --skip-signature
```

For a signed release app, run the strict verification:

```bash
./scripts/verify-universal-build.sh build/SuperIsland.app
```

The strict check runs:

```bash
lipo -info build/SuperIsland.app/Contents/MacOS/SuperIsland
codesign --verify --deep --strict --verbose=2 build/SuperIsland.app
spctl --assess --type execute --verbose build/SuperIsland.app
```

## Homebrew Cask update

The template lives at `packaging/homebrew/superisland.rb`.

After uploading a release DMG:

```bash
shasum -a 256 build/SuperIsland.dmg
```

Update:

- `version`
- `sha256`
- `url`, if the release asset path changes

Then test locally with Homebrew:

```bash
brew install --cask --no-quarantine ./packaging/homebrew/superisland.rb
brew uninstall --cask superisland
```

## Release checklist

- Run `xcodegen generate`.
- Build and smoke-test the app locally.
- Run `./scripts/build-and-release.sh --dry-run`.
- Run `./scripts/build-and-release.sh`.
- Confirm `lipo -info` reports both `arm64` and `x86_64` for the app binary and bundled runtime.
- Confirm notarization succeeds and the ticket is stapled.
- Confirm `spctl` accepts the release artifact.
- Update the Homebrew Cask version and SHA256.
- Upload the DMG and publish release notes.
