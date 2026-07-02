# Configuration

Everything workbench needs to know about a project lives in one file: **`.workbench/config.json`**. The setup wizard (`/workbench:setup`) writes it; you can also edit it by hand.

The guiding principle is **derive, don't duplicate**. The config stores your *level* and your *operational choices*. The seven coordination **dials** and the **lifecycle stages** are computed from the level at read-time — they are never written into the file, so they can't drift out of sync. Change the level and everything downstream moves with it.

---

## The shape

```json
{
  "workbench": {
    "version": "0.1.0",
    "initialized_at": "2026-06-26T12:00:00Z",
    "level": "crew"
  },
  "project": {
    "name": "Acme",
    "mission": "Ship the thing.",
    "launch_target": "2026-09-01",
    "kind": "existing",
    "topology": "multi-repo",
    "repos": [],
    "prod": {}
  },
  "way_of_working": {
    "models": "recommended",
    "verification": "recommended",
    "review": "recommended",
    "parallelism": "recommended",
    "enforcement": "warn-default",
    "continuity": "recommended",
    "graphify": "per-repo",
    "codex": "off",
    "remote": "off",
    "inception_depth": "recommended"
  },
  "dial_overrides": {},
  "lifecycle": { "in_review_cap": 10 }
}
```

The JSON Schema is in [`templates/schemas/config.schema.json`](../templates/schemas/config.schema.json). `/workbench:doctor` validates a project against it.

---

## `workbench`

| Field | Meaning |
|-------|---------|
| `version` | Plugin version that last scaffolded/upgraded this project. `/workbench:upgrade` uses it to reconcile. |
| `initialized_at` | ISO-8601 timestamp of first scaffold. |
| `level` | **The spine.** One of `solo` \| `pair` \| `crew` \| `fleet`. This single value drives the seven dials and the lifecycle stages. Change it with `/workbench:level`. |
| `.workbench/config.json` `workbench.hooks` | Project-level hook preference. `enabled` gives the full always-on Workbench experience; `disabled` keeps slash commands available but makes plugin hooks no-op for that repo. |

> This is the only place the level is stored. There is intentionally **no** persisted `dials` block and **no** `lifecycle.states` array — both are derived. See [levels.md](levels.md).

---

## `project`

| Field | Meaning |
|-------|---------|
| `name` | Display name, shown in the dashboard and the session brief. *(required)* |
| `kind` | `existing` (adopted into a repo with code) or `greenfield` (started from an idea). *(required)* |
| `mission` | One-line statement of what you're building. |
| `launch_target` | Target date or milestone, free-form. |
| `topology` | `single` or `multi-repo`. |
| `repos` | For multi-repo projects: the repositories workbench should reason about. |
| `prod` | Production URLs/endpoints the dashboard health-checks (e.g. `{ "app": "https://…", "api": "https://…" }`). |

---

## `way_of_working`

These are your **operational axes** — cross-cutting choices the setup wizard walks one card at a time. They're independent of the level: two `crew` projects can verify differently. Most axes use a `leaner` / `recommended` / `better` tier — lighter-touch through more-thorough.

| Axis | Values | Controls |
|------|--------|----------|
| `models` | leaner · recommended · better | Which model tier runs which role (cheaper vs. more capable). |
| `verification` | leaner · recommended · better | How hard the verify-gate is — self-check, an independent verifier, or several adversarial ones. |
| `review` | leaner · recommended · better | How much code review significant tasks get. |
| `parallelism` | leaner · recommended · better | How aggressively the loop runs lanes in parallel. |
| `enforcement` | remind · warn-default · strict | How forcefully guards (e.g. the multi-session commit guard) act — nudge, warn, or hard-block. |
| `continuity` | leaner · recommended · better | Depth of session/compaction checkpointing. |
| `graphify` | off · per-repo · full | Knowledge-graph integration scope. |
| `codex` | off · rescue-only · full-lane | Whether Codex collaborates, and how much. |
| `remote` | off · native · telegram · both | Phone/remote control surface. |
| `inception_depth` | leaner · recommended · better | How thorough `/workbench:inception` is for greenfield genesis. |

All ten axes are required once a project is configured.

> **`graphify` appears in two places — here's which wins.** The `way_of_working.graphify` axis above is a coarse *operational toggle* (is the knowledge graph on, and roughly how broad). The level also derives a `graphify` **dial** with a finer scope vocabulary (`off` → `per-repo` → `workspace` → `federated`). The **dial is authoritative for scope** — resolved as `dial_overrides.graphify` first, then the level preset — while the axis records the on/off intent the setup wizard captured. The wizard keeps the two aligned; if you hand-edit, change the level (or `dial_overrides.graphify`) rather than relying on the axis alone. (Knowledge-graph integration itself is on the roadmap; today both values are declarative.)

---

## `dial_overrides`

The seven dials (`team`, `release`, `decomposition`, `architecture`, `surfaces`, `graphify`, `loop_autonomy`) are normally derived from the level. This optional flat object overrides a single dial without leaving the preset:

```json
{
  "workbench": { "level": "crew" },
  "dial_overrides": { "loop_autonomy": "suggest-review" }
}
```

Resolution checks `dial_overrides.<dial>` first, then falls back to the level preset (this is what `wb_dial` in `scripts/levels.sh` does). The level label is unchanged — it now reads as "crew preset, except `loop_autonomy=suggest-review`." Document an override in your `CLAUDE.md` if it affects how agents should behave.

---

## `lifecycle`

| Field | Meaning |
|-------|---------|
| `in_review_cap` | Maximum number of tasks allowed in `in-review/` at once (default `10`). When the count nears the cap, the loop stops taking new work and drains the queue by verifying oldest-first. An unbounded review queue is where "done" claims pile up; the cap forces verification to keep happening. |

The set of lifecycle *stages* is not stored here — it's derived from the level (`solo` has the fewest, `fleet` the most). See [levels.md](levels.md#lifecycle-stages-per-level).

---

## Mesh runtime state

Workbench Mesh does not add long-lived config fields to `.workbench/config.json`. The command center is runtime state owned by the Rust `workbench-mesh` binary and the `scripts/mesh.sh` wrapper.

| File | Meaning |
|------|---------|
| `.workbench/mesh/server.json` | Ignored project runtime metadata for command-center discovery: host and port. It may include an ephemeral local daemon access token for the current server, but not the durable same-user credential or root key. `/workbench:mesh open` reads this cached snapshot to print a non-tokenized URL. |
| `$WORKBENCH_HOME/mesh/` | Durable same-user credential material and scoped LAN invite tokens (`~/.workbench/mesh/` by default). This lives outside git and should be protected with OS user-only permissions. Treat this directory as private runtime state. |
| `$WORKBENCH_HOME/mesh/statusline/<project>.json` | Cached statusline snapshot: actor presence, availability, current `doing` text, watched actors, and connected LAN devices. The statusline hook reads the cache instead of querying the live service on every prompt. |

Start modes set the auth boundary:

| Mode | Command | Boundary |
|------|---------|----------|
| Local | `/workbench:mesh start --local` | This machine only, using durable same-user credentials from `$WORKBENCH_HOME` / `~/.workbench`; ephemeral daemon metadata is not printed as invite/open URL authority. |
| LAN | `/workbench:mesh start --lan` | Trusted local network, explicit invite token for each joining device/session, accepted with `/workbench:mesh connect http://HOST:PORT TOKEN [DEVICE]`. |
| Public | Deferred | Public internet exposure is not implemented or documented as supported. |

LAN startup prints the hostname, `.local` mDNS name, raw IP address, and port so another device can connect without guessing which address works on the network. URL acceptance is supported for trusted LAN hosts only; public internet exposure remains out of scope.

---

## Editing safely

- **Change the level** with `/workbench:level up|down|<name>` rather than hand-editing — it also creates any new stage directories and shows you the dial diff first.
- **Re-running the scaffolder** (`/workbench:init`) preserves an existing config; it only re-stamps the `level` scalar when you pass an explicit new level, and never clobbers your other fields.
- **After any hand-edit**, run `/workbench:doctor` to validate against the schema and check for drift.
