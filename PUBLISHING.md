# Maintainer guide

Repository: https://github.com/mlwn4096/Bridge

Bridge is licensed under MIT. Preserve LICENSE and upstream notices in distributions.
Only the contents of bridge-app belong in this repository. The parent private-workspace
contains private signing material, installer history and excluded mirroring experiments.

## Repository settings

Suggested description: Native macOS and Android companion for local file transfers,
clipboard sharing, notifications, and phone controls. No account or cloud relay.

Topics: macos, android, swift, kotlin, file-transfer, clipboard, local-network.
Enable Issues and private vulnerability reporting. Protect main as the project grows.
Do not add collaborators or change security permissions without reviewing access needs.

## Normal development

Create a branch, make a focused change, run relevant tests and open a pull request.
Review behavior, compatibility and validation before merging. Keep device acceptance
limits visible. See CONTRIBUTING.md and docs/BUILDING.md.

## Releases

Source publication and installer distribution are separate. After device acceptance,
create a version tag and GitHub Release; use prerelease while validation remains pending.
Attach the DMG, APK, checksums and relevant build notes. Do not commit installers.
Use your backed-up release signing key for Android updates; Mac release distribution
requires your own Developer ID identity/notarization setup. Default Mac builds are
ad-hoc signed. The cached Android fallback is not a fresh dependency-resolved build.

Before release, review THIRD_PARTY_NOTICES.md and resolved dependencies, confirm artwork
rights, verify both packages and review the acceptance checklist. A project license
does not supersede third-party obligations.

## Publication and security

Open source permits forks and reuse under the license; you still own your copyright
and decide what to merge. It does not obligate unlimited support. Never commit keys,
credentials or private data; revoke/rotate secrets if exposed. Deleting a visible file
alone does not remove a secret from Git history.

## Initial publication

The initial source commit is prepared locally with origin pointing at this repository.
In the parent workspace, `publish-bridge.zsh` pushes main and applies the description,
topics, Issues and private vulnerability reporting. It uses GitHub CLI authentication,
and never force-pushes. Run it from your normal Terminal if this session cannot reach GitHub.

Existing build checks: Mac protocol/artwork checks passed; Android cached-toolchain
JVM suite passed 56 tests. Final DMG/APK package checks passed. A fresh Gradle build
and physical-device acceptance are still pending; do not describe 1.0 as audited or
production-stable on the strength of compilation alone.
