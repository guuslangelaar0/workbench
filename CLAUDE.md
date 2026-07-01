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
