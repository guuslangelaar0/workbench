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
