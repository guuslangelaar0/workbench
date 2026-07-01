# Workbench Mesh Installable Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Workbench v0.5.1 with first-use checksum-verified Mesh binary acquisition, friendly release assets, and explicit Superpowers companion integration.

**Architecture:** Keep the plugin install lightweight: the marketplace install copies the plugin, while `bin/workbench-mesh` resolves a bundled, cached, local, or bootstrapped Rust binary at runtime. Release packaging builds friendly `workbench-mesh-v<version>-<platform>.tar.gz` assets plus `checksums.txt`; docs and setup surfaces make Superpowers the recommended discipline layer for brainstorm, spec, plan, TDD, review, verification, and subagent execution.

**Tech Stack:** Bash launchers/tests, Claude Code plugin manifest JSON, GitHub Actions, Rust `workbench-mesh` binary, markdown docs/skills, `tar`, `sha256sum`/`shasum`, `curl` or Python stdlib download fallback.

## Global Constraints

- Required v0.5.1 prebuilt release assets: `workbench-mesh-v0.5.1-linux-x64.tar.gz`, `workbench-mesh-v0.5.1-linux-arm64.tar.gz`, and `workbench-mesh-v0.5.1-macos-arm64.tar.gz`.
- The launcher must still recognize `macos-x64` and print the same source-build fallback when no prebuilt asset exists.
- Each tarball layout is exactly `workbench-mesh/bin/workbench-mesh`, `workbench-mesh/VERSION`, and `workbench-mesh/PLATFORM`.
- Release `checksums.txt` lines use `<sha256>  <asset-name>`.
- Never execute a downloaded tarball before checksum verification passes.
- If `checksums.txt` is missing, malformed, or does not contain the asset name, refuse the download.
- If checksum mismatches, delete the downloaded tarball and refuse execution.
- Cache verified binaries under `${CLAUDE_PLUGIN_DATA}/mesh/bin/<version>/<platform>/workbench-mesh`.
- The bootstrap may run the local build automatically only when `WORKBENCH_MESH_BOOTSTRAP=build` is set.
- Manifest dependency target is `{ "name": "superpowers", "version": ">=6.1.0" }`; user-facing install command is `/plugin install superpowers@claude-plugins-official`.
- If `claude plugin validate --strict` rejects the dependency shape, omit the manifest dependency and keep README/setup guidance.
- Use TDD for behavior changes: write focused failing tests before implementation.
- Do not add Windows native packaging in v0.5.1.

---

### Task 1: Runtime Bootstrap And Launcher

**Files:**
- Modify: `bin/workbench-mesh`
- Create: `scripts/mesh-bootstrap.sh`
- Modify: `scripts/validate-plugin.sh`
- Modify: `test/mesh-packaging.test.sh`

**Interfaces:**
- Consumes: `.claude-plugin/plugin.json` version, `${CLAUDE_PLUGIN_DATA}`, optional `WORKBENCH_MESH_RELEASE_BASE_URL`, optional `WORKBENCH_MESH_BOOTSTRAP=build`.
- Produces: launcher order `bundled -> cached -> local release -> local debug -> bootstrap`, platform keys `linux-x64|linux-arm64|macos-arm64|macos-x64`, and verified cached binary path `${CLAUDE_PLUGIN_DATA}/mesh/bin/<version>/<platform>/workbench-mesh`.

- [ ] **Step 1: Add failing launcher/bootstrap tests**

Append focused assertions to `test/mesh-packaging.test.sh` after the existing wrapper tests. Use a fake plugin copied into a temp directory so tests do not mutate the source tree.

```bash
# --- first-use mesh binary bootstrap ---
BOOT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mesh-bootstrap.XXXXXX")"
trap 'rm -rf "$WRAP_TMP" "$BOOT_TMP"' EXIT
BOOT_PLUGIN="$BOOT_TMP/plugin"
BOOT_RELEASE="$BOOT_TMP/release"
BOOT_DATA="$BOOT_TMP/data"
mkdir -p "$BOOT_PLUGIN" "$BOOT_RELEASE" "$BOOT_DATA"
cp -R "$HERE/bin" "$HERE/scripts" "$HERE/.claude-plugin" "$BOOT_PLUGIN/"
mkdir -p "$BOOT_TMP/payload/workbench-mesh/bin"
cat > "$BOOT_TMP/payload/workbench-mesh/bin/workbench-mesh" <<'FAKEBOOT'
#!/usr/bin/env bash
printf 'bootstrapped:%s\n' "$*"
FAKEBOOT
chmod +x "$BOOT_TMP/payload/workbench-mesh/bin/workbench-mesh"
printf '0.5.1\n' > "$BOOT_TMP/payload/workbench-mesh/VERSION"
printf 'linux-x64\n' > "$BOOT_TMP/payload/workbench-mesh/PLATFORM"
tar -C "$BOOT_TMP/payload" -czf "$BOOT_RELEASE/workbench-mesh-v0.5.1-linux-x64.tar.gz" workbench-mesh
(cd "$BOOT_RELEASE" && sha256sum workbench-mesh-v0.5.1-linux-x64.tar.gz > checksums.txt)

BOOT_OUT="$BOOT_TMP/bootstrap.out"
CLAUDE_PLUGIN_DATA="$BOOT_DATA" \
WORKBENCH_MESH_RELEASE_BASE_URL="file://$BOOT_RELEASE" \
WORKBENCH_MESH_TEST_OS="Linux" \
WORKBENCH_MESH_TEST_ARCH="x86_64" \
  "$BOOT_PLUGIN/bin/workbench-mesh" hello world > "$BOOT_OUT"
chk "launcher bootstraps verified linux-x64 asset" "grep -q 'bootstrapped:hello world' '$BOOT_OUT'"
chk "launcher caches verified binary" "[ -x '$BOOT_DATA/mesh/bin/0.5.1/linux-x64/workbench-mesh' ]"

rm -rf "$BOOT_RELEASE"
CLAUDE_PLUGIN_DATA="$BOOT_DATA" \
WORKBENCH_MESH_TEST_OS="Linux" \
WORKBENCH_MESH_TEST_ARCH="x86_64" \
  "$BOOT_PLUGIN/bin/workbench-mesh" cached > "$BOOT_TMP/cached.out"
chk "launcher reuses cached binary without release directory" "grep -q 'bootstrapped:cached' '$BOOT_TMP/cached.out'"

BAD_PLUGIN="$BOOT_TMP/bad-plugin"
BAD_RELEASE="$BOOT_TMP/bad-release"
BAD_DATA="$BOOT_TMP/bad-data"
cp -R "$BOOT_PLUGIN" "$BAD_PLUGIN"
mkdir -p "$BAD_RELEASE" "$BAD_DATA"
printf 'not a tarball\n' > "$BAD_RELEASE/workbench-mesh-v0.5.1-linux-x64.tar.gz"
printf '0000000000000000000000000000000000000000000000000000000000000000  workbench-mesh-v0.5.1-linux-x64.tar.gz\n' > "$BAD_RELEASE/checksums.txt"
BAD_RC=0
CLAUDE_PLUGIN_DATA="$BAD_DATA" \
WORKBENCH_MESH_RELEASE_BASE_URL="file://$BAD_RELEASE" \
WORKBENCH_MESH_TEST_OS="Linux" \
WORKBENCH_MESH_TEST_ARCH="x86_64" \
  "$BAD_PLUGIN/bin/workbench-mesh" fail > "$BOOT_TMP/bad.out" 2>&1 || BAD_RC=$?
chk "bootstrap rejects checksum mismatch" "[ '$BAD_RC' -ne 0 ] && grep -qi 'checksum' '$BOOT_TMP/bad.out'"
chk "bootstrap does not cache bad binary" "[ ! -e '$BAD_DATA/mesh/bin/0.5.1/linux-x64/workbench-mesh' ]"

UNSUPPORTED_RC=0
CLAUDE_PLUGIN_DATA="$BOOT_TMP/unsupported-data" \
WORKBENCH_MESH_TEST_OS="Plan9" \
WORKBENCH_MESH_TEST_ARCH="x86_64" \
  "$BOOT_PLUGIN/bin/workbench-mesh" nope > "$BOOT_TMP/unsupported.out" 2>&1 || UNSUPPORTED_RC=$?
chk "launcher reports unsupported platform" "[ '$UNSUPPORTED_RC' -ne 0 ] && grep -qi 'unsupported platform Plan9/x86_64' '$BOOT_TMP/unsupported.out'"

MAC_RC=0
CLAUDE_PLUGIN_DATA="$BOOT_TMP/mac-data" \
WORKBENCH_MESH_RELEASE_BASE_URL="file://$BOOT_TMP/no-such-release" \
WORKBENCH_MESH_TEST_OS="Darwin" \
WORKBENCH_MESH_TEST_ARCH="x86_64" \
  "$BOOT_PLUGIN/bin/workbench-mesh" nope > "$BOOT_TMP/macos-x64.out" 2>&1 || MAC_RC=$?
chk "macos-x64 has source-build fallback" "[ '$MAC_RC' -ne 0 ] && grep -q 'no verified prebuilt binary available for macos-x64' '$BOOT_TMP/macos-x64.out' && grep -q 'cargo build --release -p workbench-mesh' '$BOOT_TMP/macos-x64.out'"
```

- [ ] **Step 2: Run focused test and confirm RED**

Run:

```bash
bash test/mesh-packaging.test.sh
```

Expected: FAIL on bootstrap assertions because `scripts/mesh-bootstrap.sh` does not exist and `bin/workbench-mesh` does not read `${CLAUDE_PLUGIN_DATA}` or download verified assets.

- [ ] **Step 3: Implement launcher order**

Replace `bin/workbench-mesh` with this behavior:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
os="${WORKBENCH_MESH_TEST_OS:-$(uname -s)}"
arch="${WORKBENCH_MESH_TEST_ARCH:-$(uname -m)}"

case "$os:$arch" in
  Darwin:arm64)  target="aarch64-apple-darwin"; platform="macos-arm64" ;;
  Darwin:x86_64) target="x86_64-apple-darwin"; platform="macos-x64" ;;
  Linux:aarch64|Linux:arm64) target="aarch64-unknown-linux-gnu"; platform="linux-arm64" ;;
  Linux:x86_64) target="x86_64-unknown-linux-gnu"; platform="linux-x64" ;;
  *) echo "workbench-mesh: unsupported platform $os/$arch" >&2; exit 70 ;;
esac

version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/plugin.json" | head -1)"
[ -n "$version" ] || { echo "workbench-mesh: could not read plugin version" >&2; exit 69; }

bundled="$ROOT/bin/workbench-mesh.d/$target/workbench-mesh"
if [ -x "$bundled" ]; then
  exec "$bundled" "$@"
fi

if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  cached="$CLAUDE_PLUGIN_DATA/mesh/bin/$version/$platform/workbench-mesh"
  if [ -x "$cached" ]; then
    exec "$cached" "$@"
  fi
fi

if [ -x "$ROOT/target/release/workbench-mesh" ]; then
  exec "$ROOT/target/release/workbench-mesh" "$@"
fi
if [ -x "$ROOT/target/debug/workbench-mesh" ]; then
  exec "$ROOT/target/debug/workbench-mesh" "$@"
fi

exec "$ROOT/scripts/mesh-bootstrap.sh" "$platform" "$target" "$version" "$@"
```

- [ ] **Step 4: Implement bootstrap script**

Create `scripts/mesh-bootstrap.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform="${1:-}"
target="${2:-}"
version="${3:-}"
shift 3 || true

asset="workbench-mesh-v${version}-${platform}.tar.gz"
base="${WORKBENCH_MESH_RELEASE_BASE_URL:-https://github.com/guuslangelaar0/workbench/releases/download/v${version}}"
plugin_data="${CLAUDE_PLUGIN_DATA:-}"

fallback() {
  cat >&2 <<EOF
workbench-mesh: no verified prebuilt binary available for ${platform:-unknown}
Install prerequisites:
  - Rust stable with cargo
  - macOS: Xcode Command Line Tools
  - Linux: gcc/clang toolchain (for example build-essential on Debian/Ubuntu)
Then run:
  cargo build --release -p workbench-mesh
EOF
}

if [ -z "$platform" ] || [ -z "$target" ] || [ -z "$version" ]; then
  echo "workbench-mesh: bootstrap missing platform, target, or version" >&2
  fallback
  exit 69
fi

if [ "${WORKBENCH_MESH_BOOTSTRAP:-}" = "build" ]; then
  (cd "$ROOT" && cargo build --release -p workbench-mesh)
  exec "$ROOT/target/release/workbench-mesh" "$@"
fi

if [ -z "$plugin_data" ]; then
  echo "workbench-mesh: CLAUDE_PLUGIN_DATA is not set; cannot cache verified binary" >&2
  fallback
  exit 69
fi

tmp_root="$plugin_data/mesh/tmp"
final_dir="$plugin_data/mesh/bin/$version/$platform"
tmp="$(mktemp -d "$tmp_root/bootstrap.XXXXXX" 2>/dev/null || true)"
if [ -z "$tmp" ]; then
  mkdir -p "$tmp_root"
  tmp="$(mktemp -d "$tmp_root/bootstrap.XXXXXX")"
fi
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

download() {
  src="$1"
  dest="$2"
  case "$src" in
    file://*) cp "${src#file://}" "$dest" ;;
    /*) cp "$src" "$dest" ;;
    *)
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$src" -o "$dest"
      elif command -v python3 >/dev/null 2>&1; then
        python3 - "$src" "$dest" <<'PY'
import sys, urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
      else
        return 1
      fi
      ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

url_base="${base%/}"
checksums="$tmp/checksums.txt"
tarball="$tmp/$asset"

download "$url_base/checksums.txt" "$checksums" || { fallback; exit 69; }
expected="$(awk -v asset="$asset" '$2 == asset { print $1 }' "$checksums" | head -1)"
case "$expected" in
  ""|*[!0-9a-fA-F]*) echo "workbench-mesh: checksum entry missing or malformed for $asset" >&2; rm -f "$tarball"; fallback; exit 69 ;;
esac

download "$url_base/$asset" "$tarball" || { fallback; exit 69; }
actual="$(sha256_file "$tarball")"
if [ "$actual" != "$expected" ]; then
  echo "workbench-mesh: checksum mismatch for $asset" >&2
  rm -f "$tarball"
  fallback
  exit 69
fi

extract="$tmp/extract"
mkdir -p "$extract"
tar -C "$extract" -xzf "$tarball"
candidate="$extract/workbench-mesh/bin/workbench-mesh"
if [ ! -f "$candidate" ]; then
  echo "workbench-mesh: asset missing workbench-mesh/bin/workbench-mesh" >&2
  fallback
  exit 69
fi
chmod +x "$candidate"
install_tmp="$plugin_data/mesh/bin/$version/.${platform}.tmp.$$"
rm -rf "$install_tmp"
mkdir -p "$install_tmp"
cp "$candidate" "$install_tmp/workbench-mesh"
chmod +x "$install_tmp/workbench-mesh"
mkdir -p "$(dirname "$final_dir")"
rm -rf "$final_dir"
mv "$install_tmp" "$final_dir"
exec "$final_dir/workbench-mesh" "$@"
```

- [ ] **Step 5: Update validator for bootstrap support**

In `scripts/validate-plugin.sh`, replace the `clear_error` check with a `bootstrap_support` check:

```python
bootstrap = os.path.join(root, "scripts", "mesh-bootstrap.sh")
bootstrap_support = (
    os.path.isfile(bootstrap)
    and os.access(bootstrap, os.X_OK)
    and "mesh-bootstrap.sh" in launcher_body
    and "CLAUDE_PLUGIN_DATA" in launcher_body
)
clear_error = (
    "packaged binary missing" in launcher_body
    and "cargo build -p workbench-mesh" in launcher_body
)
if not packaged_bins and not (bootstrap_support or clear_error):
    err("bin/workbench-mesh has no packaged target binaries and no bootstrap downloader/checksum support")
```

Also add `bash -n scripts/mesh-bootstrap.sh` validation when the file exists.

- [ ] **Step 6: Run focused tests and commit**

Run:

```bash
chmod +x scripts/mesh-bootstrap.sh
bash test/mesh-packaging.test.sh
bash scripts/validate-plugin.sh
```

Expected: both pass.

Commit:

```bash
git add bin/workbench-mesh scripts/mesh-bootstrap.sh scripts/validate-plugin.sh test/mesh-packaging.test.sh
git commit -m "feat: bootstrap verified mesh binaries"
```

### Task 2: Friendly Release Assets And Checksums

**Files:**
- Create: `scripts/package-mesh-asset.sh`
- Modify: `.github/workflows/release-binaries.yml`
- Modify: `test/mesh-packaging.test.sh`

**Interfaces:**
- Consumes: built binary at `target/<rust-target>/release/workbench-mesh`.
- Produces: `dist/workbench-mesh-v<version>-<platform>.tar.gz` with layout `workbench-mesh/bin/workbench-mesh`, `VERSION`, `PLATFORM`.
- Produces: workflow artifact set containing three required platform tarballs and `checksums.txt`.

- [ ] **Step 1: Add failing packaging assertions**

Append to `test/mesh-packaging.test.sh`:

```bash
# --- friendly release asset packaging ---
PKG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mesh-package.XXXXXX")"
trap 'rm -rf "$WRAP_TMP" "$BOOT_TMP" "$PKG_TMP"' EXIT
mkdir -p "$PKG_TMP/repo/target/x86_64-unknown-linux-gnu/release" "$PKG_TMP/out"
cat > "$PKG_TMP/repo/target/x86_64-unknown-linux-gnu/release/workbench-mesh" <<'FAKEPKG'
#!/usr/bin/env bash
echo packaged
FAKEPKG
chmod +x "$PKG_TMP/repo/target/x86_64-unknown-linux-gnu/release/workbench-mesh"
(cd "$PKG_TMP/repo" && bash "$HERE/scripts/package-mesh-asset.sh" x86_64-unknown-linux-gnu linux-x64 0.5.1 "$PKG_TMP/out")
chk "packager creates friendly asset name" "[ -f '$PKG_TMP/out/workbench-mesh-v0.5.1-linux-x64.tar.gz' ]"
tar -C "$PKG_TMP/out" -tzf "$PKG_TMP/out/workbench-mesh-v0.5.1-linux-x64.tar.gz" > "$PKG_TMP/tar.list"
chk "packager uses product layout" "grep -qx 'workbench-mesh/bin/workbench-mesh' '$PKG_TMP/tar.list' && grep -qx 'workbench-mesh/VERSION' '$PKG_TMP/tar.list' && grep -qx 'workbench-mesh/PLATFORM' '$PKG_TMP/tar.list'"
tar -C "$PKG_TMP/out/extract" -xzf "$PKG_TMP/out/workbench-mesh-v0.5.1-linux-x64.tar.gz" 2>/dev/null || mkdir -p "$PKG_TMP/out/extract"
rm -rf "$PKG_TMP/out/extract"
mkdir -p "$PKG_TMP/out/extract"
tar -C "$PKG_TMP/out/extract" -xzf "$PKG_TMP/out/workbench-mesh-v0.5.1-linux-x64.tar.gz"
chk "packager writes version and platform" "grep -qx '0.5.1' '$PKG_TMP/out/extract/workbench-mesh/VERSION' && grep -qx 'linux-x64' '$PKG_TMP/out/extract/workbench-mesh/PLATFORM'"

chk "release workflow declares linux-x64 asset" "grep -q 'platform: linux-x64' '$HERE/.github/workflows/release-binaries.yml'"
chk "release workflow declares linux-arm64 asset" "grep -q 'platform: linux-arm64' '$HERE/.github/workflows/release-binaries.yml'"
chk "release workflow declares macos-arm64 asset" "grep -q 'platform: macos-arm64' '$HERE/.github/workflows/release-binaries.yml'"
chk "release workflow omits macos intel runner" "! grep -q 'macos-15-intel' '$HERE/.github/workflows/release-binaries.yml'"
chk "release workflow uploads checksums" "grep -q 'checksums.txt' '$HERE/.github/workflows/release-binaries.yml'"
chk "release workflow uploads release assets on tags" "grep -q 'gh release upload' '$HERE/.github/workflows/release-binaries.yml'"
chk "release workflow avoids target-triple asset names" "! grep -q 'workbench-mesh-${{ matrix.target }}' '$HERE/.github/workflows/release-binaries.yml'"
```

- [ ] **Step 2: Run focused test and confirm RED**

Run:

```bash
bash test/mesh-packaging.test.sh
```

Expected: FAIL because `scripts/package-mesh-asset.sh` is missing and workflow still uses target-triple archive names.

- [ ] **Step 3: Create package helper**

Create `scripts/package-mesh-asset.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
target="${1:-}"
platform="${2:-}"
version="${3:-}"
out="${4:-dist}"
[ -n "$target" ] && [ -n "$platform" ] && [ -n "$version" ] || {
  echo "usage: package-mesh-asset.sh TARGET PLATFORM VERSION OUT_DIR" >&2
  exit 2
}
binary="target/$target/release/workbench-mesh"
[ -x "$binary" ] || { echo "package-mesh-asset: missing executable $binary" >&2; exit 1; }
stage="$(mktemp -d "${TMPDIR:-/tmp}/workbench-mesh-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/workbench-mesh/bin" "$out"
cp "$binary" "$stage/workbench-mesh/bin/workbench-mesh"
chmod +x "$stage/workbench-mesh/bin/workbench-mesh"
printf '%s\n' "$version" > "$stage/workbench-mesh/VERSION"
printf '%s\n' "$platform" > "$stage/workbench-mesh/PLATFORM"
tar -C "$stage" -czf "$out/workbench-mesh-v${version}-${platform}.tar.gz" workbench-mesh
```

- [ ] **Step 4: Rewrite release workflow**

Update `.github/workflows/release-binaries.yml` to:

```yaml
name: Release mesh binaries

on:
  workflow_dispatch:
  push:
    tags:
      - "v*"

permissions:
  contents: write

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: ubuntu-latest
            target: x86_64-unknown-linux-gnu
            platform: linux-x64
          - os: ubuntu-latest
            target: aarch64-unknown-linux-gnu
            platform: linux-arm64
          - os: macos-14
            target: aarch64-apple-darwin
            platform: macos-arm64
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: ${{ matrix.target }}
      - uses: Swatinem/rust-cache@v2
      - name: Install cross for Linux ARM
        if: matrix.target == 'aarch64-unknown-linux-gnu'
        run: cargo install cross --locked
      - name: Build release binary
        run: |
          if [ "${{ matrix.target }}" = "aarch64-unknown-linux-gnu" ]; then
            cross build --release -p workbench-mesh --target "${{ matrix.target }}"
          else
            cargo build --release -p workbench-mesh --target "${{ matrix.target }}"
          fi
      - name: Package friendly asset
        run: |
          version="${GITHUB_REF_NAME#v}"
          if [ "$version" = "$GITHUB_REF_NAME" ]; then
            version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .claude-plugin/plugin.json | head -1)"
          fi
          bash scripts/package-mesh-asset.sh "${{ matrix.target }}" "${{ matrix.platform }}" "$version" dist
      - uses: actions/upload-artifact@v4
        with:
          name: workbench-mesh-${{ matrix.platform }}
          path: dist/workbench-mesh-*.tar.gz

  publish:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          pattern: workbench-mesh-*
          path: dist
          merge-multiple: true
      - name: Generate checksums
        run: |
          cd dist
          sha256sum workbench-mesh-*.tar.gz > checksums.txt
      - uses: actions/upload-artifact@v4
        with:
          name: workbench-mesh-checksums
          path: dist/checksums.txt
      - name: Attach assets to GitHub release
        if: startsWith(github.ref, 'refs/tags/')
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh release upload "$GITHUB_REF_NAME" dist/workbench-mesh-*.tar.gz dist/checksums.txt --clobber
```

- [ ] **Step 5: Run focused tests and commit**

Run:

```bash
chmod +x scripts/package-mesh-asset.sh
bash test/mesh-packaging.test.sh
```

Expected: PASS.

Commit:

```bash
git add scripts/package-mesh-asset.sh .github/workflows/release-binaries.yml test/mesh-packaging.test.sh
git commit -m "ci: publish friendly mesh assets"
```

### Task 3: Superpowers Integration And Install Docs

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `README.md`
- Modify: `docs/commands.md`
- Modify: `skills/setup/SKILL.md`
- Modify: `skills/orchestration/SKILL.md`
- Modify: `test/skills.test.sh`
- Modify: `test/marketplace.test.sh`

**Interfaces:**
- Consumes: Claude Code plugin dependency manifest field.
- Produces: Superpowers dependency when validation accepts it, setup guidance when missing, and docs that explain first-use Mesh binary acquisition.

- [ ] **Step 1: Add failing docs/integration assertions**

Extend `test/skills.test.sh`:

```bash
SETUP="$HERE/skills/setup/SKILL.md"
ORCH="$HERE/skills/orchestration/SKILL.md"
chk "setup guides missing superpowers install" "grep -q '/plugin install superpowers@claude-plugins-official' '$SETUP'"
chk "setup maps discipline intents to superpowers" "grep -q 'superpowers:brainstorming' '$SETUP' && grep -q 'superpowers:test-driven-development' '$SETUP' && grep -q 'superpowers:verification-before-completion' '$SETUP'"
chk "orchestration names superpowers discipline loop" "grep -q 'superpowers:subagent-driven-development' '$ORCH' && grep -q 'superpowers:test-driven-development' '$ORCH'"
```

Extend `test/marketplace.test.sh`:

```bash
chk "plugin declares superpowers dependency or docs fallback" "python3 - <<'PY' '$HERE/.claude-plugin/plugin.json' '$HERE/README.md'
import json, sys
pj=json.load(open(sys.argv[1]))
deps=pj.get('dependencies', [])
ok=any(isinstance(d, dict) and d.get('name')=='superpowers' and d.get('version')=='>=6.1.0' for d in deps)
docs='/plugin install superpowers@claude-plugins-official' in open(sys.argv[2]).read()
raise SystemExit(0 if (ok or docs) else 1)
PY"
chk "README documents Superpowers" "grep -q 'Superpowers' '$HERE/README.md' && grep -q '/plugin install superpowers@claude-plugins-official' '$HERE/README.md'"
chk "README documents verified Mesh binary acquisition" "grep -q 'checksum-verified' '$HERE/README.md' && grep -q 'checksums.txt' '$HERE/README.md'"
```

- [ ] **Step 2: Run focused tests and confirm RED**

Run:

```bash
bash test/skills.test.sh
bash test/marketplace.test.sh
```

Expected: FAIL because README/setup/orchestration do not yet carry the new guidance.

- [ ] **Step 3: Add manifest dependency**

Add this field to `.claude-plugin/plugin.json` after `keywords`:

```json
  "dependencies": [
    { "name": "superpowers", "version": ">=6.1.0" }
  ]
```

Then run:

```bash
claude plugin validate . --strict
```

Expected: PASS. If this command fails specifically because `dependencies` is rejected, remove the field and keep the README/setup guidance; record the validation output in the task report.

- [ ] **Step 4: Update README**

In `README.md`:

1. In Install, recommend Superpowers before Workbench:

```text
/plugin install superpowers@claude-plugins-official
/plugin marketplace add guuslangelaar0/workbench
/plugin install workbench@workbench
```

2. Add this paragraph after the install command block:

```markdown
Workbench declares Superpowers as its companion discipline plugin on Claude Code versions that support plugin dependencies. If your Claude Code build does not auto-install it, install it explicitly with `/plugin install superpowers@claude-plugins-official`.
```

3. Add this paragraph near the Mesh quickstart/docs:

```markdown
On first `/workbench:mesh` use, Workbench resolves the Rust binary in this order: bundled binary, checksum-verified cached binary under `${CLAUDE_PLUGIN_DATA}`, local development build, then a GitHub release download verified against `checksums.txt`. If no verified asset exists for your platform, it prints the exact `cargo build --release -p workbench-mesh` fallback instead of running an unsigned binary.
```

4. In `Works with`, add:

```markdown
- **[Superpowers](https://github.com/anthropics/claude-code/tree/main/plugins/superpowers)** — the companion discipline layer for brainstorm -> spec -> plan, TDD, code review, verification-before-completion, and subagent-driven development. Workbench routes those intents to Superpowers when it is installed.
```

- [ ] **Step 5: Update command and skill guidance**

In `docs/commands.md`, extend `/workbench:mesh start --local` with the first-run verified-binary paragraph from Step 4.

In `skills/setup/SKILL.md`, add a new Step 0a after project assessment:

```markdown
## Step 0a: Check Superpowers availability

Run `claude plugin list --json` when the CLI is available. If `superpowers@claude-plugins-official` is not installed/enabled, tell the user:

```text
Workbench works best with Superpowers for brainstorm -> spec -> plan, TDD, code review, verification-before-completion, and subagent-driven development.
Install it with:
/plugin install superpowers@claude-plugins-official
```

Map these user intents to Superpowers when available:
- "brainstorm/spec this properly" -> `superpowers:brainstorming`
- "write the implementation plan" -> `superpowers:writing-plans`
- "build this test-first" -> `superpowers:test-driven-development`
- "build with subagents" -> `superpowers:subagent-driven-development`
- "review before shipping" -> `superpowers:requesting-code-review`
- "prove it is done" -> `superpowers:verification-before-completion`
```

In `skills/orchestration/SKILL.md`, add a compact operating rule:

```markdown
When work needs implementation discipline, route through Superpowers: brainstorm/spec before feature creation, `superpowers:writing-plans` before multi-step builds, `superpowers:subagent-driven-development` for independent task execution, `superpowers:test-driven-development` for behavior changes, and `superpowers:verification-before-completion` before claiming done.
```

- [ ] **Step 6: Run focused tests and commit**

Run:

```bash
bash test/skills.test.sh
bash test/marketplace.test.sh
bash scripts/validate-plugin.sh
claude plugin validate . --strict
```

Expected: all pass, except `claude plugin validate . --strict` may be omitted from commit gating only if the CLI is unavailable; if unavailable, record that in the report.

Commit:

```bash
git add .claude-plugin/plugin.json README.md docs/commands.md skills/setup/SKILL.md skills/orchestration/SKILL.md test/skills.test.sh test/marketplace.test.sh
git commit -m "docs: integrate superpowers guidance"
```

### Task 4: v0.5.1 Release Metadata

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `test/marketplace.test.sh`

**Interfaces:**
- Consumes: completed Tasks 1-3.
- Produces: plugin version `0.5.1`, changelog section `[0.5.1] - 2026-07-01`, and release notes that mention new features, bug fixes, and changes.

- [ ] **Step 1: Add failing version/release assertions**

Extend `test/marketplace.test.sh`:

```bash
chk "plugin version is v0.5.1" "[ \"$(python3 -c 'import json;print(json.load(open(\"'$HERE'/.claude-plugin/plugin.json\"))[\"version\"])')\" = 0.5.1 ]"
chk "marketplace version is v0.5.1" "[ \"$(python3 -c 'import json;print(json.load(open(\"'$HERE'/.claude-plugin/marketplace.json\"))[\"plugins\"][0][\"version\"])')\" = 0.5.1 ]"
chk "changelog has v0.5.1 date" "grep -q '^## \\[0.5.1\\] - 2026-07-01' '$HERE/CHANGELOG.md'"
chk "changelog names checksum assets" "grep -qi 'checksum-verified' '$HERE/CHANGELOG.md' && grep -q 'checksums.txt' '$HERE/CHANGELOG.md'"
```

- [ ] **Step 2: Run focused test and confirm RED**

Run:

```bash
bash test/marketplace.test.sh
```

Expected: FAIL because versions are still `0.5.0` and changelog lacks `0.5.1`.

- [ ] **Step 3: Bump manifest versions**

Set `.claude-plugin/plugin.json` `"version"` to `"0.5.1"`.

Set `.claude-plugin/marketplace.json` plugin entry `"version"` to `"0.5.1"`.

- [ ] **Step 4: Add changelog release notes**

In `CHANGELOG.md`, add below `[Unreleased]`:

```markdown
## [0.5.1] - 2026-07-01

### Added
- Mesh first-use binary acquisition: `/workbench:mesh` now resolves a bundled, cached, local, or GitHub release binary and stores verified downloads under `${CLAUDE_PLUGIN_DATA}`.
- Superpowers integration guidance: Workbench declares/points to Superpowers for brainstorm -> spec -> plan, TDD, code review, verification, and subagent-driven development.

### Changed
- Mesh release assets use friendly names such as `workbench-mesh-v0.5.1-linux-x64.tar.gz` instead of raw Rust target triples, with a `checksums.txt` file for SHA-256 verification.
- The release workflow publishes Linux x64, Linux ARM64, and macOS ARM64 Mesh assets, while macOS Intel stays on the source-build fallback path.

### Fixed
- Marketplace installs no longer leave Mesh users stranded with only a local Rust build hint; unsupported or unavailable platforms now get a clear, secure fallback without executing unsigned downloads.
```

- [ ] **Step 5: Run focused tests and commit**

Run:

```bash
bash test/marketplace.test.sh
bash scripts/validate-plugin.sh
```

Expected: both pass.

Commit:

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json CHANGELOG.md README.md test/marketplace.test.sh
git commit -m "release: prepare v0.5.1 metadata"
```

### Task 5: Verification And Release

**Files:**
- No source files expected.
- Create if useful: `docs/releases/v0.5.1.md` for local release notes handed to `gh release create`.

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: verified commit ready for tag `v0.5.1`; release assets are produced by `.github/workflows/release-binaries.yml` when GitHub Actions minutes are available.

- [ ] **Step 1: Run full local verification**

Run:

```bash
cargo fmt --check
cargo test --workspace
cargo build -p workbench-mesh
bash test/all.sh
bash scripts/validate-plugin.sh
git diff --check
```

Expected: all pass.

- [ ] **Step 2: Run live e2e if available**

Run:

```bash
WB_E2E=1 bash test/e2e/run.sh
```

Expected: PASS when the local Claude CLI is authenticated. If it skips or fails because credentials/API are unavailable, record that exact output and continue only if all offline suites passed.

- [ ] **Step 3: Check release asset feasibility**

Run:

```bash
gh auth status
gh api repos/guuslangelaar0/workbench/actions/runs --jq '.workflow_runs[0:5][] | "\(.name) \(.head_branch) \(.conclusion)"'
```

If GitHub Actions minutes are unavailable, do not claim all v0.5.1 prebuilt assets exist. Create the tag/release only when the release workflow can run, or publish source release notes that explicitly say prebuilt assets will appear when Actions capacity returns.

- [ ] **Step 4: Tag and publish when assets can be produced**

Run:

```bash
git status --short
git tag -a v0.5.1 -m "v0.5.1"
git push origin main
git push origin v0.5.1
```

Expected: tag push triggers `.github/workflows/release-binaries.yml`; the `publish` job attaches `workbench-mesh-v0.5.1-linux-x64.tar.gz`, `workbench-mesh-v0.5.1-linux-arm64.tar.gz`, `workbench-mesh-v0.5.1-macos-arm64.tar.gz`, and `checksums.txt` to the GitHub release.

- [ ] **Step 5: Verify release assets**

Run:

```bash
gh release view v0.5.1 --json tagName,name,assets,isDraft,isPrerelease
```

Expected: the release has the three required friendly tarballs plus `checksums.txt`.

Commit only if release notes file was created:

```bash
git add docs/releases/v0.5.1.md
git commit -m "docs: add v0.5.1 release notes"
```

## Plan Self-Review

- Spec coverage: Tasks 1-2 cover runtime bootstrap, checksum verification, cache location, fallback, friendly asset layout, checksums, and workflow upload. Task 3 covers Superpowers dependency/guidance and install/docs. Task 4 covers v0.5.1 metadata and release notes. Task 5 covers final verification and release asset checks.
- Completeness scan: the implementation steps contain concrete files, commands, expected failures, expected passes, and commit scopes.
- Type/interface consistency: platform keys, asset names, cache path, dependency object, and version `0.5.1` match the spec.
