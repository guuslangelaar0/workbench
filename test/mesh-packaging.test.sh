#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; fail=1; fi; }
contains() { grep -Fq "$2" "$1"; }

chk "bin launcher exists" "[ -f '$HERE/bin/workbench-mesh' ]"
chk "bin launcher executable" "[ -x '$HERE/bin/workbench-mesh' ]"
chk "scripts mesh wrapper exists" "[ -f '$HERE/scripts/mesh.sh' ]"
chk "mesh wrapper syntactically valid" "bash -n '$HERE/scripts/mesh.sh'"
chk "mesh command exists" "[ -f '$HERE/commands/mesh.md' ]"
chk "mesh command calls mesh.sh" "grep -q 'scripts/mesh.sh' '$HERE/commands/mesh.md'"
chk "mesh skill exists" "[ -f '$HERE/skills/mesh/SKILL.md' ]"
chk "validate plugin knows bin surface" "bash '$HERE/scripts/validate-plugin.sh' '$HERE' | grep -q 'publishable'"

WRAP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mesh-wrapper.XXXXXX")"
trap 'rm -rf "$WRAP_TMP"' EXIT
FAKE_PLUGIN="$WRAP_TMP/plugin"
PROJECT_DIR="$WRAP_TMP/project"
MESH_HOME="$WRAP_TMP/home"
LOG="$WRAP_TMP/argv.log"
mkdir -p "$FAKE_PLUGIN/bin" "$PROJECT_DIR/.workbench/mesh" "$MESH_HOME"
cat > "$FAKE_PLUGIN/bin/workbench-mesh" <<'FAKE'
#!/usr/bin/env bash
{
  printf 'cmd'
  for arg in "$@"; do
    printf '|%s' "$arg"
  done
  printf '\n'
} >> "${MESH_FAKE_LOG:?}"

if [ "${1:-}" = "invite" ] && [ "${2:-}" = "create" ]; then
  printf 'token: fake-token\nrole: worker\nexpires: later\nmax_uses: 1\n'
fi
FAKE
chmod +x "$FAKE_PLUGIN/bin/workbench-mesh"
printf '{"host":"127.0.0.1","port":47321}\n' > "$PROJECT_DIR/.workbench/mesh/server.json"

run_wrapper() {
  CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" \
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
  WORKBENCH_HOME="$MESH_HOME" \
  MESH_FAKE_LOG="$LOG" \
  bash "$HERE/scripts/mesh.sh" "$@"
}

: > "$LOG"
run_wrapper start > "$WRAP_TMP/start.out" 2>&1
chk "wrapper start bootstraps auth" "contains '$LOG' 'cmd|auth|bootstrap|--target|$PROJECT_DIR|--home|$MESH_HOME'"
chk "wrapper start serves local" "contains '$LOG' 'cmd|serve|--target|$PROJECT_DIR|--home|$MESH_HOME|--bind|local'"
chk "wrapper start default output avoids port zero URL" "! contains '$WRAP_TMP/start.out' 'http://127.0.0.1:0'"
chk "wrapper start default output points to metadata" "contains '$WRAP_TMP/start.out' '.workbench/mesh/server.json'"

: > "$LOG"
run_wrapper invite --ttl-seconds 60 > "$WRAP_TMP/invite.out" 2>&1
chk "wrapper invite defaults worker role" "contains '$LOG' 'cmd|invite|create|--target|$PROJECT_DIR|--home|$MESH_HOME|--role|worker|--ttl-seconds|60'"
chk "wrapper invite prints metadata URL" "contains '$WRAP_TMP/invite.out' 'url: http://127.0.0.1:47321'"

: > "$LOG"
run_wrapper connect local-token laptop > "$WRAP_TMP/connect-local.out" 2>&1
chk "wrapper connect local token accepts invite" "contains '$LOG' 'cmd|invite|accept|--target|$PROJECT_DIR|--home|$MESH_HOME|--token|local-token|--device|laptop'"

: > "$LOG"
run_wrapper connect http://192.0.2.10:47321 remote-token tablet > "$WRAP_TMP/connect-url.out" 2>&1
chk "wrapper connect URL accepts remote invite" "contains '$LOG' 'cmd|invite|accept|--target|$PROJECT_DIR|--home|$MESH_HOME|--url|http://192.0.2.10:47321|--token|remote-token|--device|tablet'"
chk "wrapper connect URL no longer fails unsupported" "! contains '$WRAP_TMP/connect-url.out' 'remote URL connect is not supported'"

: > "$LOG"
run_wrapper help > "$WRAP_TMP/help.out" 2>&1
chk "wrapper help advertises URL connect syntax" "contains '$WRAP_TMP/help.out' 'connect [URL] TOKEN [DEVICE]'"
chk "wrapper help documents devices operation" "contains '$WRAP_TMP/help.out' 'devices'"
chk "wrapper help documents revoke-device operation" "contains '$WRAP_TMP/help.out' 'revoke-device DEVICE'"

: > "$LOG"
run_wrapper status > "$WRAP_TMP/status.out" 2>&1
run_wrapper who > "$WRAP_TMP/who.out" 2>&1
run_wrapper room lead:checkout > "$WRAP_TMP/room.out" 2>&1
run_wrapper message lead:checkout hello mesh > "$WRAP_TMP/message.out" 2>&1
run_wrapper ask session:worker what now > "$WRAP_TMP/ask.out" 2>&1
run_wrapper handoff TASK-7 session:worker > "$WRAP_TMP/handoff.out" 2>&1
run_wrapper jobs --since 4 > "$WRAP_TMP/jobs.out" 2>&1
run_wrapper availability busy --reason reviewing > "$WRAP_TMP/availability.out" 2>&1
run_wrapper doing reviewing task five > "$WRAP_TMP/doing.out" 2>&1
run_wrapper watch session:worker > "$WRAP_TMP/watch.out" 2>&1
run_wrapper devices > "$WRAP_TMP/devices.out" 2>&1
run_wrapper revoke-device laptop > "$WRAP_TMP/revoke-device.out" 2>&1
chk "wrapper status passes target and home" "contains '$LOG' 'cmd|status|--target|$PROJECT_DIR|--home|$MESH_HOME'"
chk "wrapper who passes target and home" "contains '$LOG' 'cmd|who|--target|$PROJECT_DIR|--home|$MESH_HOME'"
chk "wrapper room emits create argv" "contains '$LOG' 'cmd|room|create|--target|$PROJECT_DIR|--home|$MESH_HOME|--name|lead:checkout'"
chk "wrapper message emits text as one argv" "contains '$LOG' 'cmd|message|--target|$PROJECT_DIR|--home|$MESH_HOME|--to|lead:checkout|--text|hello mesh'"
chk "wrapper ask emits question as one argv" "contains '$LOG' 'cmd|ask|--target|$PROJECT_DIR|--home|$MESH_HOME|--to|session:worker|--question|what now'"
chk "wrapper handoff emits task and target" "contains '$LOG' 'cmd|handoff|--target|$PROJECT_DIR|--home|$MESH_HOME|--task-id|TASK-7|--to|session:worker'"
chk "wrapper jobs delegates to rust jobs" "contains '$LOG' 'cmd|jobs|--target|$PROJECT_DIR|--home|$MESH_HOME|--since|4'"
chk "wrapper jobs does not own event list filtering" "! contains '$LOG' 'cmd|event|list'"
chk "wrapper availability passes state and reason" "contains '$LOG' 'cmd|availability|--target|$PROJECT_DIR|--home|$MESH_HOME|busy|--reason|reviewing'"
chk "wrapper doing emits text as one argv" "contains '$LOG' 'cmd|doing|--target|$PROJECT_DIR|--home|$MESH_HOME|reviewing task five'"
chk "wrapper watch passes actor" "contains '$LOG' 'cmd|watch|--target|$PROJECT_DIR|--home|$MESH_HOME|session:worker'"
chk "wrapper devices delegates to rust device list" "contains '$LOG' 'cmd|device|list|--target|$PROJECT_DIR|--home|$MESH_HOME'"
chk "wrapper revoke-device delegates to rust device revoke" "contains '$LOG' 'cmd|device|revoke|--target|$PROJECT_DIR|--home|$MESH_HOME|--device|laptop'"

: > "$LOG"
run_wrapper open > "$WRAP_TMP/open.out" 2>&1
chk "wrapper open reads metadata without invoking rust" "contains '$WRAP_TMP/open.out' 'Command center: http://127.0.0.1:47321'"
chk "wrapper open does not call rust binary" "[ ! -s '$LOG' ]"

printf '{"host":"127.0.0.1","port":47321,"local_token":"fake-local-token"}\n' > "$PROJECT_DIR/.workbench/mesh/server.json"
: > "$LOG"
run_wrapper open > "$WRAP_TMP/open-token.out" 2>&1
chk "wrapper open does not print local token from metadata" "contains '$WRAP_TMP/open-token.out' 'Command center: http://127.0.0.1:47321' && ! contains '$WRAP_TMP/open-token.out' 'fake-local-token' && ! contains '$WRAP_TMP/open-token.out' 'token='"
chk "wrapper tokenized open does not call rust binary" "[ ! -s '$LOG' ]"

# --- first-use mesh binary bootstrap ---
BOOT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mesh-bootstrap.XXXXXX")"
trap 'rm -rf "$WRAP_TMP" "$BOOT_TMP"' EXIT
BOOT_PLUGIN="$BOOT_TMP/plugin"
BOOT_RELEASE="$BOOT_TMP/release"
BOOT_DATA="$BOOT_TMP/data"
mkdir -p "$BOOT_PLUGIN" "$BOOT_RELEASE" "$BOOT_DATA"
cp -R "$HERE/bin" "$HERE/scripts" "$HERE/.claude-plugin" "$BOOT_PLUGIN/"
python3 - "$BOOT_PLUGIN/.claude-plugin/plugin.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data["version"] = "0.5.1"
with open(path, "w") as f:
    json.dump(data, f)
    f.write("\n")
PY
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

ATOMIC_RELEASE="$BOOT_TMP/atomic-release"
mkdir -p "$ATOMIC_RELEASE" "$BOOT_TMP/payload-v2/workbench-mesh/bin"
cat > "$BOOT_TMP/payload-v2/workbench-mesh/bin/workbench-mesh" <<'FAKEBOOTV2'
#!/usr/bin/env bash
printf 'bootstrapped-v2:%s\n' "$*"
FAKEBOOTV2
chmod +x "$BOOT_TMP/payload-v2/workbench-mesh/bin/workbench-mesh"
printf '0.5.1\n' > "$BOOT_TMP/payload-v2/workbench-mesh/VERSION"
printf 'linux-x64\n' > "$BOOT_TMP/payload-v2/workbench-mesh/PLATFORM"
tar -C "$BOOT_TMP/payload-v2" -czf "$ATOMIC_RELEASE/workbench-mesh-v0.5.1-linux-x64.tar.gz" workbench-mesh
(cd "$ATOMIC_RELEASE" && sha256sum workbench-mesh-v0.5.1-linux-x64.tar.gz > checksums.txt)
printf 'keep\n' > "$BOOT_DATA/mesh/bin/0.5.1/linux-x64/marker"
CLAUDE_PLUGIN_DATA="$BOOT_DATA" \
WORKBENCH_MESH_RELEASE_BASE_URL="file://$ATOMIC_RELEASE" \
  bash "$BOOT_PLUGIN/scripts/mesh-bootstrap.sh" linux-x64 x86_64-unknown-linux-gnu 0.5.1 atomic > "$BOOT_TMP/atomic.out"
chk "bootstrap atomically replaces cached binary file" "grep -q 'bootstrapped-v2:atomic' '$BOOT_TMP/atomic.out' && [ -f '$BOOT_DATA/mesh/bin/0.5.1/linux-x64/marker' ]"

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

CORRUPT_RELEASE="$BOOT_TMP/corrupt-release"
CORRUPT_DATA="$BOOT_TMP/corrupt-data"
mkdir -p "$CORRUPT_RELEASE" "$CORRUPT_DATA"
printf 'not a tarball\n' > "$CORRUPT_RELEASE/workbench-mesh-v0.5.1-linux-x64.tar.gz"
(cd "$CORRUPT_RELEASE" && sha256sum workbench-mesh-v0.5.1-linux-x64.tar.gz > checksums.txt)
CORRUPT_RC=0
CLAUDE_PLUGIN_DATA="$CORRUPT_DATA" \
WORKBENCH_MESH_RELEASE_BASE_URL="file://$CORRUPT_RELEASE" \
WORKBENCH_MESH_TEST_OS="Linux" \
WORKBENCH_MESH_TEST_ARCH="x86_64" \
  "$BOOT_PLUGIN/bin/workbench-mesh" fail > "$BOOT_TMP/corrupt.out" 2>&1 || CORRUPT_RC=$?
chk "bootstrap reports extract failure with fallback" "[ '$CORRUPT_RC' -ne 0 ] && grep -qi 'failed to extract' '$BOOT_TMP/corrupt.out' && grep -q 'cargo build --release -p workbench-mesh' '$BOOT_TMP/corrupt.out'"
chk "bootstrap does not cache corrupt archive binary" "[ ! -e '$CORRUPT_DATA/mesh/bin/0.5.1/linux-x64/workbench-mesh' ]"

MALFORMED_RELEASE="$BOOT_TMP/malformed-release"
MALFORMED_DATA="$BOOT_TMP/malformed-data"
mkdir -p "$MALFORMED_RELEASE" "$MALFORMED_DATA"
printf 'abc  workbench-mesh-v0.5.1-linux-x64.tar.gz\n' > "$MALFORMED_RELEASE/checksums.txt"
MALFORMED_RC=0
CLAUDE_PLUGIN_DATA="$MALFORMED_DATA" \
WORKBENCH_MESH_RELEASE_BASE_URL="file://$MALFORMED_RELEASE" \
WORKBENCH_MESH_TEST_OS="Linux" \
WORKBENCH_MESH_TEST_ARCH="x86_64" \
  "$BOOT_PLUGIN/bin/workbench-mesh" fail > "$BOOT_TMP/malformed.out" 2>&1 || MALFORMED_RC=$?
chk "bootstrap rejects malformed checksum length before asset download" "[ '$MALFORMED_RC' -ne 0 ] && grep -qi 'checksum entry missing or malformed' '$BOOT_TMP/malformed.out' && ! grep -qi 'No such file' '$BOOT_TMP/malformed.out'"
chk "bootstrap does not cache malformed checksum binary" "[ ! -e '$MALFORMED_DATA/mesh/bin/0.5.1/linux-x64/workbench-mesh' ]"

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
chk "release workflow creates release before upload" "grep -q 'gh release create' '$HERE/.github/workflows/release-binaries.yml'"
chk "release workflow uploads release assets on tags" "grep -q 'gh release upload' '$HERE/.github/workflows/release-binaries.yml'"
chk "release workflow provides GitHub repo context" "grep -q 'GH_REPO:' '$HERE/.github/workflows/release-binaries.yml' || grep -q -- '--repo' '$HERE/.github/workflows/release-binaries.yml'"
chk "release workflow avoids target-triple asset names" "! grep -q 'workbench-mesh-\${{ matrix.target }}' '$HERE/.github/workflows/release-binaries.yml'"

[ "$fail" = 0 ] && echo "PASS: mesh-packaging" || { echo "mesh-packaging test failed"; exit 1; }
