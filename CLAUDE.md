# Workbench Plugin Development

This repository builds the Workbench Claude Code plugin. Follow
`CONTRIBUTING.md` for the contributor workflow and keep generated project
guidance in `templates/` aligned with repo-level guidance.

## Release Notes Contract

When creating or editing a GitHub release, keep the release notes consistent with
the established Workbench style from `v0.2.0` onward:

- Title format: `vX.Y.Z — short release name`.
- Body starts with one concise release paragraph.
- Use these sections, when relevant: `### What's New`, `### Changes`,
  `### Bug Fixes / Hardening`, `### Verification`, and `### Assets`.
- Verification must name the real commands/results used for that release.
- Binary/assets releases must list attached assets and checksum files.
- Do not leave auto-generated release text like "Workbench mesh binaries for
  vX.Y.Z"; edit the GitHub release and read it back before calling the release
  finished.

## Release Deployment Procedure

When the user asks to deploy/release a Workbench version:

- Prepare a release commit on the feature branch that bumps
  `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`, promotes
  `CHANGELOG.md` from `Unreleased` into `## [X.Y.Z] - YYYY-MM-DD`, and keeps the
  release notes in the contract above.
- Run the relevant release gate before merging. For Mesh releases this includes
  `cargo fmt --check`, `cargo test -p workbench-mesh`, the Mesh shell suites,
  `bash scripts/validate-plugin.sh`, `bash scripts/bench.sh`, and
  `git diff --check`.
- Merge the verified branch to `main`, rerun the release gate on `main`, then
  push `main` and tag the same commit as `vX.Y.Z`.
- The `Release mesh binaries` workflow is tag-driven and should attach
  `workbench-mesh-vX.Y.Z-linux-x64.tar.gz`,
  `workbench-mesh-vX.Y.Z-linux-arm64.tar.gz`,
  `workbench-mesh-vX.Y.Z-macos-arm64.tar.gz`, and `checksums.txt`.
- After the workflow finishes, edit the GitHub release title/body into the
  established style, list the actual assets, and read the release back with
  `gh release view` before reporting it as deployed.
