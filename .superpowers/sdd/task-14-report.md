# Task 14 Report: CI — add `cmake` to the release workflow and verify a real cross-compiled build

Branch: `feat/mesh-lan-tls-pinning`, base commit `75f3b91`.

## Summary

Added a runner-level `cmake` bootstrap step to `.github/workflows/release-binaries.yml`
(covers the native `ubuntu-latest`/x86_64 build and the `macos-14`/aarch64-apple-darwin
build) and a `Cross.toml` `pre-build` step that installs `cmake` inside the `cross`
Docker container used for the `aarch64-unknown-linux-gnu` build. Both are required
because this branch depends on `aws-lc-rs` (via `reqwest`/`tokio-tungstenite`), whose
`aws-lc-sys` build script compiles C/assembly and needs `cmake` at build time.

Verified for real, not by inspection: installed `cross` locally, ran
`cross build --release -p workbench-mesh --target aarch64-unknown-linux-gnu` against
this branch's `Cargo.toml`, and confirmed a genuine ARM64 ELF binary was produced with
no cmake/aws-lc-sys build-script failure.

## Files changed

- `.github/workflows/release-binaries.yml` — new step `Ensure cmake is available
  (aws-lc-rs build dependency)` inserted between `Swatinem/rust-cache@v2` and
  `Install cross for Linux ARM` (matches the brief's exact insertion point; file line
  numbers had not drifted from the brief's citation).
- `Cross.toml` (new file, repo root) — `[target.aarch64-unknown-linux-gnu]` with
  `pre-build = ["apt-get update && apt-get install -y cmake"]`. No pre-existing
  `Cross.toml` was found anywhere in the repo (`find . -maxdepth 2 -iname "Cross.toml"`
  returned nothing), so this is a new file, exactly as the brief anticipated for that
  case.

### Diff

```diff
diff --git a/.github/workflows/release-binaries.yml b/.github/workflows/release-binaries.yml
index 617e0ae..6a9056f 100644
--- a/.github/workflows/release-binaries.yml
+++ b/.github/workflows/release-binaries.yml
@@ -31,6 +31,16 @@ jobs:
         with:
           targets: ${{ matrix.target }}
       - uses: Swatinem/rust-cache@v2
+      - name: Ensure cmake is available (aws-lc-rs build dependency)
+        run: |
+          if ! command -v cmake >/dev/null 2>&1; then
+            if [ "${{ matrix.os }}" = "macos-14" ]; then
+              brew install cmake
+            else
+              sudo apt-get update && sudo apt-get install -y cmake
+            fi
+          fi
+          cmake --version
       - name: Install cross for Linux ARM
         if: matrix.target == 'aarch64-unknown-linux-gnu'
         run: cargo install cross --locked
```

```
diff --git a/Cross.toml b/Cross.toml
new file mode 100644
--- /dev/null
+++ b/Cross.toml
@@ -0,0 +1,2 @@
+[target.aarch64-unknown-linux-gnu]
+pre-build = ["apt-get update && apt-get install -y cmake"]
```

Both snippets are applied verbatim from the brief with no adjustments needed.

## Verification

### 1. Real cross-compiled build (the load-bearing check)

Environment check before starting: Docker was confirmed installed and running
(`docker info` succeeded), and `cross` was confirmed *not* pre-installed
(`which cross` → not found) — matching the brief's assumed starting state.

```
$ cargo install cross --locked
   Compiling ... (57 crates)
    Finished `release` profile [optimized] target(s) in 34.46s
  Installing /home/guus/.cargo/bin/cross
  Installing /home/guus/.cargo/bin/cross-util
   Installed package `cross v0.2.5` (executables `cross`, `cross-util`)
```

**Environment wrinkle (not related to this task's changes):** this machine's `PATH`
puts Arch Linux's system `/bin/rustc` and `/bin/cargo` (pacman-installed) ahead of the
rustup shims in `~/.cargo/bin`. `cross` shells out to resolve the active rustup
toolchain, and against the system rustc (`sysroot` = `/usr`) it mis-parsed `usr` as a
toolchain name and failed with `couldn't install toolchain 'usr'` — a local PATH
ordering artifact, reproducible even with a bare `cross --version` on this box, and
unrelated to cmake or to this task's diff. Fixed by exporting
`PATH="$HOME/.cargo/bin:$PATH"` before invoking `cross`, which resolves to the
rustup-managed `stable-x86_64-unknown-linux-gnu` toolchain. Noting this so it isn't
mistaken for a build failure caused by the workflow/Cross.toml changes — it is purely
this machine's shell setup and does not affect GitHub Actions runners (which use
rustup-first `PATH`s by default via `dtolnay/rust-toolchain@stable`).

With `PATH` corrected, the real verification build:

```
$ export PATH="$HOME/.cargo/bin:$PATH"
$ cross build --release -p workbench-mesh --target aarch64-unknown-linux-gnu
```

- Start: `2026-07-25T10:44:05Z`
- End: `2026-07-25T10:45:39Z`
- Duration: ~1m34s (rustup pulled a toolchain component update it wanted first; the
  cross-rs `aarch64-unknown-linux-gnu:0.2.5` Docker image and crates.io registry were
  already warm on this box, which is why it was faster than the "expect this to take a
  while" guidance in the task instructions — a cold-cache run pulling the ~1-2GB
  cross-rs image and compiling `aws-lc-sys`'s C/assembly from scratch would take
  noticeably longer)
- Exit code (confirmed directly on a second run, see below): `0`

Tail of the build log, showing the `Cross.toml` `pre-build` step installing `cmake`
**inside the container** (this is the part that would fail without Step 2's fix), then
`aws-lc-sys` compiling cleanly, then a successful finish:

```
#5 [2/2] RUN eval "apt-get update && apt-get install -y cmake"
#5 4.380   cmake-data libarchive13 libcurl3 libicu55 libjsoncpp1 liblzo2-2 libxml2
#5 4.504 Get:2 http://archive.archive.ubuntu.com/ubuntu xenial-updates/main amd64 cmake-data all 3.5.1-1ubuntu3 [1121 kB]
#5 4.993 Get:9 http://archive.archive.ubuntu.com/ubuntu xenial-updates/main amd64 cmake amd64 3.5.1-1ubuntu3 [2623 kB]
#5 7.156 Selecting previously unselected package cmake.
#5 7.787 Setting up cmake-data (3.5.1-1ubuntu3) ...
#5 7.787 Setting up cmake (3.5.1-1ubuntu3) ...
...
   Compiling cmake v0.1.58
   Compiling aws-lc-sys v0.42.0
   ...
   Compiling reqwest v0.12.28
   Compiling tokio-tungstenite v0.24.0
   Compiling axum v0.7.9
   Compiling workbench-mesh v0.5.0 (/project/crates/workbench-mesh)
    Finished `release` profile [optimized] target(s) in 38.14s
```

No `cmake: command not found`, no `aws-lc-sys` build-script error, anywhere in the
build log (`grep -in "error\|failed\|not found"` over the full log matched only crate
names like `thiserror`, `serde_path_to_error` — no actual errors).

Confirmed artifact on disk:

```
$ ls -la target/aarch64-unknown-linux-gnu/release/workbench-mesh
-rwxr-xr-x 2 guus guus 13611296 Jul 25 12:45 target/aarch64-unknown-linux-gnu/release/workbench-mesh
$ file target/aarch64-unknown-linux-gnu/release/workbench-mesh
target/aarch64-unknown-linux-gnu/release/workbench-mesh: ELF 64-bit LSB pie executable,
ARM aarch64, version 1 (SYSV), dynamically linked, interpreter /lib/ld-linux-aarch64.so.1,
for GNU/Linux 3.7.0, BuildID[sha1]=677f14659c2a174c3b52df06acc6b0d5044a92bb, not stripped
```

A real ARM64 Linux binary — not the host's x86_64 — confirming the cross-compilation
(container + `Cross.toml` pre-build + `aws-lc-rs`/`aws-lc-sys` native build) genuinely
succeeded end to end.

For belt-and-suspenders, re-ran `cross build` a second time immediately after (same
command, same PATH) to capture a clean, unambiguous exit code directly from the shell
rather than through a `PIPESTATUS`-under-`tee` capture that came back empty on the
first run:

```
$ cross build --release -p workbench-mesh --target aarch64-unknown-linux-gnu
#5 [2/2] RUN eval "apt-get update && apt-get install -y cmake"
#5 CACHED
    Finished `release` profile [optimized] target(s) in 0.11s
EXIT_CODE_DIRECT=0
```

This second run also confirms the `Cross.toml` pre-build layer is cached correctly by
Docker (`#5 CACHED`) — it was applied and executed once and is now reused, as expected.

### 2. `cargo test -p workbench-mesh` (native, no cross)

```
test result: ok. 152 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.66s
   Running unittests src/main.rs (target/debug/deps/workbench_mesh-...)
test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
   Doc-tests workbench_mesh
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

All green — 157 tests total (152 lib + 5 bin), 0 failures. Already green from prior
tasks; this task's changes don't touch Rust source and didn't regress anything.

### 3. `bash test/all.sh`

Ran to completion, 68 `===` sections, final line:

```
ALL TESTS PASS
```

No unexpected failures (`grep -i fail` over the full log only matches expected
test-name substrings like "fails on empty project" / "gate FAILS when routing table
removed" — all intentional negative-path assertions, not real failures).

## Deviations from the brief

None in the applied changes — both YAML and `Cross.toml` snippets were inserted
verbatim at the exact locations the brief specified (line numbers had not drifted).

One deviation in *how* verification was carried out versus the brief's Step 3 wording:
the brief offers either a local Docker/cross run or a GitHub Actions
`workflow_dispatch` run as the two acceptable verification paths. Per this task's
explicit dispatch instructions, only the local path was used (pushing the branch or
triggering the remote workflow is explicitly out of scope for this task and requires
separate human authorization) — this matches the brief's own carve-out for when local
Docker is available, which it is here.

## Concerns

- **PATH-ordering issue on this machine** (see above) had to be worked around to get
  `cross` to resolve the correct toolchain. This is specific to this local dev
  environment's Arch Linux system-Rust-vs-rustup PATH ordering and does not apply to
  GitHub Actions runners, which install Rust via `dtolnay/rust-toolchain@stable` (a
  rustup-based action with no competing system Rust on `PATH`). No workflow change was
  made for this — it would be out of place to "fix" a local dev-machine PATH quirk in
  CI YAML that doesn't have the quirk. Flagging it here in case it recurs for another
  contributor with a similar system-Rust-plus-rustup setup running `cross` locally.
- The verification build was faster (~1.5 min total, most of it a rustup toolchain
  sync) than the "expect this to take a while" guidance suggested, because the
  cross-rs Docker image and crates.io index were already warm on this machine from
  earlier work on this host. A first-ever cold-cache run (fresh image pull + full
  `aws-lc-sys` C/assembly compile) would be expected to take several minutes longer;
  that is normal and not a sign of a problem.
- Committed only `.github/workflows/release-binaries.yml`, `Cross.toml`, and this
  report file, per the task instructions (which supersede the brief's Step 4 command
  block that omits the report file) — did **not** stage the pre-existing unrelated
  modification to `.superpowers/sdd/task-7-report.md` or the untracked
  `.playwright-mcp/`/`.workbench/` directories.
- Did not push the branch or trigger the GitHub Actions workflow remotely, per
  explicit instruction — that remains out of scope for this task.
- This report file overwrites stale content that was previously saved at this same
  path (an unrelated frontend/UI task report from an earlier plan iteration that
  reused the "Task 14" number). Overwriting was intentional per this dispatch's
  explicit instruction to write the report to this exact path.

## Result

DONE — real local `cross build` verification succeeded (exit 0, genuine ARM64 ELF
binary produced), `cargo test -p workbench-mesh` is green (157/157), and
`bash test/all.sh` reports `ALL TESTS PASS`.
