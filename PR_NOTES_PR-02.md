# PR-02 Notes

Title: Add universal build verification and Homebrew Cask packaging

Branch: `distribution/universal-build-homebrew-notarization`

Linked issue:
- #60 Support brew install

Summary:
- Updates local and release DMG scripts to target universal `arm64 x86_64` builds.
- Adds a shared Node.js runtime bundling script that creates a universal bundled runtime.
- Adds a universal build verification script for app and runtime binaries.
- Adds dry-run preflight support and clearer missing-command/signing-credential errors.
- Adds a Homebrew Cask template under `packaging/homebrew/`.
- Adds release, notarization, verification, and Cask update documentation.
- Keeps unsigned local builds separate from signed maintainer release builds.

Validation:
- `bash -n` passed for release and packaging scripts.
- `ruby -c packaging/homebrew/superisland.rb` passed.
- `git diff --check` passed.
- `./scripts/bundle-node-runtime.sh build/SuperIsland.app --dry-run` passed.
- `./scripts/verify-universal-build.sh --help` passed.
- `./scripts/build-dmg.sh --dry-run` failed clearly because `xcodegen` is unavailable locally.
- `./scripts/build-and-release.sh --dry-run` failed clearly because `xcodegen` is unavailable locally.
- `xcodebuild -version` reported Xcode 26.5.
- `xcodegen generate` could not run because `xcodegen` is unavailable locally.

Screenshots needed:
- None. This PR changes release scripts and documentation only.

Risk notes:
- Universal runtime bundling downloads two Node.js archives instead of one, so release builds depend on both upstream archive URLs.
- Maintainers should run the full release script on a machine with XcodeGen, signing credentials, and notarization credentials before publishing.
- The Homebrew Cask keeps a placeholder SHA256 until a real release DMG is uploaded.

PR status:
- Branch is prepared locally.
- PR was not opened locally because the GitHub CLI is unavailable.
