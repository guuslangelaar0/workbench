# Workbench Mesh Installable Distribution Design

## Context

Workbench v0.5.0 introduced Workbench Mesh as a Rust-backed local/LAN control plane, but the marketplace install path is not yet good enough:

```text
/plugin marketplace add guuslangelaar0/workbench
/plugin install workbench@workbench
```

That install copies the plugin into Claude Code's plugin cache. It does not compile Rust, and it does not automatically download GitHub release assets. Today, `/workbench:mesh` only works when a matching binary is already bundled in `bin/workbench-mesh.d/<target>/workbench-mesh`, or when the user has already built `target/release/workbench-mesh` or `target/debug/workbench-mesh` inside the plugin source.

Claude Code's plugin reference gives us two relevant primitives:

- Plugin dependencies can be declared in `.claude-plugin/plugin.json`; Claude Code enables dependencies transitively when the dependent plugin is active.
- `${CLAUDE_PLUGIN_DATA}` is a persistent per-plugin data directory intended for installed dependencies, generated files, caches, and other state that survives plugin updates.

Workbench v0.5.1 should use those primitives instead of making users discover a Rust build step after install.

## Goals

1. A user who installs Workbench from the marketplace can run `/workbench:mesh start --local` and get a working mesh binary without manual setup on supported platforms.
2. Public binary assets use friendly product names, not raw Rust target triples.
3. Binary downloads are SHA-256 verified before execution.
4. The bootstrap stores binaries outside the versioned plugin cache so updates do not force needless rebuilds or redownloads.
5. If download is unavailable, the user gets exact local-build prerequisites and a deterministic fallback path.
6. Workbench treats Superpowers as a first-class companion: installable as a plugin dependency where supported, documented in README, and mapped from user intent in Workbench setup/orchestration surfaces.

## Non-Goals

- No public internet mesh exposure. This remains out of scope.
- No unsigned binary execution.
- No silent best-effort execution of a binary that fails checksum verification.
- No Windows native packaging in v0.5.1.
- No custom Claude Code plugin installer hook. The plugin system does not provide one; Workbench bootstraps at runtime.

## Platform Matrix

Required prebuilt release assets for v0.5.1:

| Platform key | OS / Arch | Asset name |
| --- | --- | --- |
| `linux-x64` | Linux `x86_64` | `workbench-mesh-v0.5.1-linux-x64.tar.gz` |
| `linux-arm64` | Linux `aarch64` / `arm64` | `workbench-mesh-v0.5.1-linux-arm64.tar.gz` |
| `macos-arm64` | macOS Apple Silicon | `workbench-mesh-v0.5.1-macos-arm64.tar.gz` |

The launcher must still recognize `macos-x64` and print the same source-build fallback when no prebuilt asset exists. macOS Intel can be added later as `workbench-mesh-v0.5.1-macos-x64.tar.gz` without changing the launcher contract.

## Asset Layout

Each tarball contains a simple product layout:

```text
workbench-mesh/
  bin/
    workbench-mesh
  VERSION
  PLATFORM
```

The archive name is user-facing. The internal Rust target triple remains an implementation detail in the build workflow and launcher mapping only.

The release also includes:

```text
checksums.txt
```

Format:

```text
<sha256>  workbench-mesh-v0.5.1-linux-x64.tar.gz
<sha256>  workbench-mesh-v0.5.1-linux-arm64.tar.gz
<sha256>  workbench-mesh-v0.5.1-macos-arm64.tar.gz
```

If a later release includes macOS Intel, it adds one more line for `workbench-mesh-v<version>-macos-x64.tar.gz` using the same format.

## Runtime Bootstrap

`bin/workbench-mesh` keeps its current fast paths:

1. Execute a bundled binary at `bin/workbench-mesh.d/<target>/workbench-mesh` if one exists.
2. Execute a cached binary in `${CLAUDE_PLUGIN_DATA}/mesh/bin/<version>/<platform>/workbench-mesh` if one exists.
3. Execute local development binaries under `target/release` or `target/debug`.
4. Run `scripts/mesh-bootstrap.sh` to acquire a binary.

`scripts/mesh-bootstrap.sh` is responsible for:

1. Detecting OS/arch and mapping it to a friendly platform key plus Rust target triple.
2. Reading the Workbench plugin version from `.claude-plugin/plugin.json`.
3. Building the GitHub release URL for `https://github.com/guuslangelaar0/workbench/releases/download/v<version>/`.
4. Downloading `checksums.txt` and the matching asset with `curl` or `python3` stdlib.
5. Verifying the downloaded tarball against `checksums.txt` using `sha256sum` or `shasum -a 256`.
6. Extracting the binary into `${CLAUDE_PLUGIN_DATA}/mesh/bin/<version>/<platform>/workbench-mesh`.
7. Executing the cached binary with the original arguments.

If any step fails before execution, bootstrap must print a concise diagnostic and the local fallback:

```text
workbench-mesh: no verified prebuilt binary available for <platform>
Install prerequisites:
  - Rust stable with cargo
  - macOS: Xcode Command Line Tools
  - Linux: gcc/clang toolchain (for example build-essential on Debian/Ubuntu)
Then run:
  cargo build --release -p workbench-mesh
```

The bootstrap may run the local build automatically only when `WORKBENCH_MESH_BOOTSTRAP=build` is set. Default behavior should avoid surprising users with a long compile when they asked to start a service.

## Security Model

- Never execute a downloaded tarball before checksum verification passes.
- If `checksums.txt` is missing, malformed, or does not contain the asset name, refuse the download.
- If checksum mismatches, delete the downloaded tarball and refuse execution.
- Use a temporary download directory under `${CLAUDE_PLUGIN_DATA}/mesh/tmp/`.
- Use an atomic move into the final cache path after extraction and permission fix-up.
- Ensure the final binary is executable.
- Do not use shell-expanded untrusted filenames from remote content; asset names are derived locally from version and platform.

## Superpowers Integration

Workbench already leans on Superpowers for the build discipline: brainstorm, spec, plan, TDD, code review, verification, and subagent-driven execution. v0.5.1 makes that relationship explicit.

Changes:

1. Add a plugin dependency using the manifest schema supported by Claude Code:

```json
{ "name": "superpowers", "version": ">=6.1.0" }
```

   The user-facing install command remains marketplace-qualified:

```text
/plugin install superpowers@claude-plugins-official
```

   Implementation must validate this with `claude plugin validate --strict` before release. If validation fails on the current Claude Code CLI, ship the README/setup guidance and omit the manifest dependency rather than publishing a broken manifest.
2. README `Works with` includes Superpowers and describes it as the discipline engine behind brainstorm -> spec -> plan, TDD, code review, and verification-before-completion.
3. README install section recommends:

```text
/plugin install superpowers@claude-plugins-official
/plugin install workbench@workbench
```

4. `skills/setup/SKILL.md` tells the user when Superpowers is missing and gives the install command.
5. Workbench command/skill surfaces map user intent such as "plan this feature properly", "build with subagents", "review this before shipping", and "use TDD" to the relevant Superpowers skills when available.

## Release Workflow

`.github/workflows/release-binaries.yml` should:

1. Build each platform binary.
2. Package each binary with the friendly asset layout and friendly filename.
3. Generate `checksums.txt`.
4. Upload all assets as workflow artifacts.
5. Attach assets to the GitHub release when triggered by a version tag.

If attaching assets from GitHub Actions requires extra permissions, the workflow must declare them explicitly:

```yaml
permissions:
  contents: write
```

## Documentation

README updates:

- Install section explains that `/plugin install` installs the plugin, and Mesh downloads a verified binary on first use.
- Mesh section explains the first-run bootstrap and fallback local build.
- Works With includes Superpowers.
- Tests/release section references friendly assets and `checksums.txt`.

Release notes for v0.5.1 should state:

- Mesh now auto-acquires a checksum-verified binary on first use.
- Friendly assets replace target-triple release artifacts.
- Superpowers is documented and guided as Workbench's companion discipline plugin.

## Testing

Offline tests:

1. Platform mapping test for Linux x64, Linux ARM64, macOS ARM64, macOS x64, and unsupported platforms.
2. Bootstrap test with local fixture release directory:
   - downloads asset
   - verifies checksum
   - extracts executable
   - reuses cache on second invocation
3. Bootstrap checksum mismatch test refuses execution and deletes the bad tarball.
4. Launcher test confirms it checks bundled, cached, local release/debug, then bootstrap paths in order.
5. Release workflow structural test confirms friendly names and `checksums.txt` generation.
6. README/docs tests confirm Superpowers install guidance and Works With entry.
7. `scripts/validate-plugin.sh` confirms the Mesh command has either bundled binaries or bootstrap downloader/checksum support.

Full verification before v0.5.1 release:

```bash
cargo fmt --check
cargo test --workspace
cargo build -p workbench-mesh
bash test/all.sh
bash scripts/validate-plugin.sh
git diff --check
WB_E2E=1 bash test/e2e/run.sh
```

## Resolved Decisions

1. The manifest dependency is `{ "name": "superpowers", "version": ">=6.1.0" }`; the install command shown to users is `/plugin install superpowers@claude-plugins-official`.
2. v0.5.1 requires Linux x64, Linux ARM64, and macOS ARM64 release assets. macOS x64 remains a source-build fallback until Actions capacity is available.
