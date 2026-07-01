# AGENTS.md

This repository is the Workbench Claude Code plugin. For contribution details,
read `CONTRIBUTING.md`; for generated project guidance, update the templates
under `templates/`.

## Release Notes Contract

When creating or editing a GitHub release, keep the release notes consistent with
the established Workbench style from `v0.2.0` onward:

- Title format: `vX.Y.Z — short release name`.
- Body starts with one concise release paragraph.
- Use these sections, when relevant: `### What's New`, `### Changes`,
  `### Bug Fixes / Hardening`, `### Verification`, and `### Assets`.
- Verification must name the real commands/results used for that release, including the
  `scripts/release-gate.sh --live` evidence path or an explicit live-skip reason.
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
- Run `bash scripts/release-gate.sh --live` before merging a release branch. It
  runs the offline gate plus `WB_E2E=1 test/e2e/run.sh` and `WB_BENCH=1
  scripts/bench-intents.sh`, fails if a required live layer skips, and writes evidence
  under `.workbench/release/`. If live cannot run, say so explicitly in the
  release notes; do not call the release live-tested.
- Merge the verified branch to `main`, rerun the release gate on `main`, then
  push `main` and tag the same commit as `vX.Y.Z`.
- The `Release mesh binaries` workflow is tag-driven and should attach
  `workbench-mesh-vX.Y.Z-linux-x64.tar.gz`,
  `workbench-mesh-vX.Y.Z-linux-arm64.tar.gz`,
  `workbench-mesh-vX.Y.Z-macos-arm64.tar.gz`, and `checksums.txt`.
- After the workflow finishes, edit the GitHub release title/body into the
  established style, list the actual assets, and read the release back with
  `gh release view` before reporting it as deployed.
