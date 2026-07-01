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
