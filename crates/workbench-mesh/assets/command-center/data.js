// Workbench Mesh — static content + live collection scaffolding.
// The live collections (AGENTS, CHAT, ROOMS, …) start empty and are
// populated by live.js from the real event log over HTTP/WebSocket.
// The docs content (LEVELS, DIALS, C4, commands, guides, FAQ) is static.
window.WB = window.WB || {};
(function (WB) {
  // Filled in by live.js from /api/state's host object (never local_token).
  WB.HOST = {
    machine: '…',
    port: 0,
    mode: 'local',
    lanIp: '127.0.0.1',
    startedBy: 'unknown',
    startedAt: Date.now(),
    pidFile: '.workbench/mesh/mesh.pid',
    orphanedSince: Date.now(),
    downSince: Date.now(),
  };

  WB.AGENTS = [];
  WB.ROOMS = [];
  WB.CHAT = [];
  WB.DECISIONS = [];
  WB.TASKS = [];
  WB.IN_REVIEW_CAP = 10;
  WB.ENROLLMENT = { hold: false };
  WB.DEVICES = [];
  WB.INVITES = [];
  WB.AUDIT = [];
  WB.JOBS = [];
  WB.LEADS = [];
  WB.EVENTS = [];

  WB.LEVELS = {
    solo: {
      label: 'Solo', blurb: 'One person, one voice. Push-to-main, flat tasks.',
      cols: ['backlog', 'in-development', 'verified'],
      structure: ['single repo', 'push-to-main'],
      dirs: ['.claude/tasks/backlog/', '.claude/tasks/in-development/', '.claude/tasks/verified/'],
    },
    pair: {
      label: 'Pair', blurb: '2–3 contributors. Feature branches, light epics.',
      cols: ['backlog', 'in-development', 'in-review', 'verified'],
      structure: ['single repo', 'feature branches + PR review'],
      dirs: ['.claude/tasks/backlog/', '.claude/tasks/in-development/', '.claude/tasks/in-review/', '.claude/tasks/verified/', '.claude/epics/', '.claude/architecture/context.md'],
    },
    crew: {
      label: 'Crew', blurb: '3–8 people. Tagged releases, epics, CI gates.',
      cols: ['backlog', 'in-development', 'in-review', 'verified', 'staged', 'shipped'],
      structure: ['single repo', 'feature branches + PR review', 'tagged releases', 'CI gates on staged'],
      dirs: ['.claude/tasks/backlog/', '.claude/tasks/in-development/', '.claude/tasks/in-review/', '.claude/tasks/verified/', '.claude/tasks/staged/', '.claude/tasks/shipped/', '.claude/epics/', '.claude/architecture/context.md', '.claude/architecture/containers.md', '.claude/evolve/personas.json'],
    },
    fleet: {
      label: 'Fleet', blurb: '8+ contributors. Release trains, federated repos.',
      cols: ['backlog', 'in-development', 'in-review', 'verified', 'staged', 'release-candidate', 'shipped'],
      structure: ['repos split by track (federated)', 'feature branches + PR review', 'release trains across repos', 'CI gates on staged', 'cross-repo epics'],
      dirs: ['.claude/tasks/backlog/', '.claude/tasks/in-development/', '.claude/tasks/in-review/', '.claude/tasks/verified/', '.claude/tasks/staged/', '.claude/tasks/release-candidate/', '.claude/tasks/shipped/', '.claude/epics/', '.claude/architecture/context.md', '.claude/architecture/containers.md', '.claude/architecture/components/', '.claude/evolve/personas.json', '.claude/release-trains.json'],
    },
  };
  WB.LEVEL_ORDER = ['solo', 'pair', 'crew', 'fleet'];

  WB.DIALS = [
    { name: 'lifecycle', vals: ['3 stages', '4 stages', '6 stages', '7 stages'] },
    { name: 'in_review_cap', vals: ['—', '6', '10', '16'] },
    { name: 'epics', vals: ['off', 'light', 'on', 'on + trains'] },
    { name: 'architecture', vals: ['none', 'context', 'containers', 'components'] },
    { name: 'verification', vals: ['build', 'build + test', 'full ladder', 'ladder + live'] },
    { name: 'dispatch_lanes', vals: ['single', '2 lanes', 'per track', 'federated'] },
    { name: 'evolve', vals: ['off', 'off', 'monthly', 'weekly'] },
  ];

  WB.C4 = {
    l1: [
      { name: 'you (operator)', desc: 'Reads this dashboard; answers decisions; holds the only revoke power.' },
      { name: 'workbench plugin', desc: 'The /workbench:* command surface inside each Claude or Codex session.' },
      { name: 'project repo', desc: 'Tasks, epics, decisions and architecture live as files under .claude/.' },
      { name: 'mesh daemon', desc: 'workbench-mesh serve — event log, presence, invites. Serves this page.' },
      { name: 'enrolled devices', desc: 'Machines admitted by invite; local or trusted-LAN transport only.' },
      { name: 'telegram remote', desc: 'Status + decision resolution from a phone while a session is live.' },
    ],
    l2: [
      { name: 'http api', desc: 'Bearer-token endpoints for roster, rooms, jobs, devices.' },
      { name: 'event log', desc: 'Append-only JSONL — every message, handoff, heartbeat, audit entry.' },
      { name: 'presence registry', desc: 'Heartbeat recency per actor; the pulse you see on the bench.' },
      { name: 'credential store', desc: 'One-way hashes only. redacted_devices() strips them from every response.' },
      { name: 'wb-coord / lane.sh', desc: 'Claim, dispatch and lifecycle transitions from the CLI side.' },
      { name: 'output tailer', desc: 'Planned: wraps each session’s stream-json, emits output.chunk.', planned: true },
    ],
    l3: [
      { name: 'protocol.rs', desc: 'Event envelope + the allowed event-type registry.' },
      { name: 'store.rs', desc: 'Append-only event rooms; coordination and output:* feeds alike.' },
      { name: 'auth.rs', desc: 'Role-scoped, short-lived invites; token surfaces exactly once. One-way credential hashes.' },
      { name: 'server.rs', desc: 'The axum HTTP/WebSocket surface this dashboard talks to.' },
      { name: 'tailer/boundary.rs', desc: 'Maps stream-json frames to output.chunk boundaries.', planned: true },
    ],
    drift: 'run /workbench:architecture drift for the live comparison',
  };

  WB.REPO_URL = 'https://github.com/guuslangelaar0/workbench';

  WB.WHAT_IS = [
    'A maturity ladder (Solo → Fleet) that scales process to team size — dials, not defaults.',
    'A teamlead loop that picks, dispatches, verify-gates and hands off work without stopping.',
    'A mesh: live roster, team chat and per-agent output shared across sessions and devices.',
    'This dashboard — a local/trusted-LAN read on the same event log the CLI already writes.',
  ];
  WB.WHAT_IS_NOT = [
    'Not a hosted, multi-tenant product — no public internet exposure, no CA-trusted TLS, by design.',
    'Not a replacement for git, CI or human judgement — decisions and level changes are recommend-only.',
    'Not a chat network for every agent — team agents route through their lead; only leads join the mesh.',
    'Not a redundant system — one host, no failover (see Host).',
  ];

  WB.COMMAND_GROUPS = [
    {
      group: 'Onboarding & front door',
      items: [
        { cmd: '/workbench:workbench', desc: 'The front door — adoption wizard on an unconfigured project, status on a configured one.' },
        { cmd: '/workbench:setup', desc: 'Explicit re-run of the wizard, for reconfiguring one axis later.' },
        { cmd: '/workbench:init', desc: 'Low-level scaffold with explicit flags — --level, --profile, --hooks.' },
        { cmd: '/workbench:boot', desc: 'Resume protocol: verify reality on disk, reconcile drift, brief facts-only.' },
        { cmd: '/workbench:upgrade', desc: 'Reconcile managed files to the installed plugin version.' },
        { cmd: '/workbench:uninstall', desc: 'Remove workbench-managed files — dry-run by default.' },
        { cmd: '/workbench:self-test', desc: 'Run the plugin’s own source self-test.' },
      ],
    },
    {
      group: 'Task & epic lifecycle',
      items: [
        { cmd: '/workbench:task "<title>"', desc: 'Create a backlog task.' },
        { cmd: '/workbench:epic / epic list', desc: 'Create or list epics — Pair level and up.' },
        { cmd: '/workbench:epic close <id>', desc: 'Close an epic once every linked task is terminal.' },
        { cmd: '/workbench:decision "<title>"', desc: 'Capture an irreversible fork into decisions/.' },
        { cmd: '/workbench:decision resolve <id>', desc: 'Mark a decision resolved once a human has answered it.' },
        { cmd: '/workbench:park "<title>"', desc: 'Park committed out-of-scope work as a real backlog task.' },
        { cmd: '/workbench:verify <id>', desc: 'Run the verification ladder, gate to verified/.' },
      ],
    },
    {
      group: 'Orchestration & dispatch',
      items: [
        { cmd: '/workbench:loop', desc: 'The teamlead loop — drain, dispatch, verify-gate, never stop.' },
        { cmd: '/workbench:dispatch <id>', desc: 'Generic dispatch — --engine claude|codex.' },
        { cmd: '/workbench:codex-engineer <id>', desc: 'Native Codex engineer lane with disk-lease fallback tracking.' },
        { cmd: '/workbench:next', desc: 'Preflight — reports cap pressure or dependency blocks before picking.' },
        { cmd: '/workbench:inception', desc: 'Turn an idea into a v1 spec + seeded backlog.' },
      ],
    },
    {
      group: 'Coordination & mesh',
      items: [
        { cmd: '/workbench:teamlead <topic>', desc: 'Become a topic lead, with a liveness check other sessions see.' },
        { cmd: '/workbench:lead status|set|adopt|clear', desc: 'Set, inspect, adopt or clear this session’s lead purpose.' },
        { cmd: '/workbench:mesh', desc: 'This dashboard’s CLI — start, stop, status, invite, devices, room, message, jobs.' },
        { cmd: '/workbench:remote', desc: 'Status + decisions from Telegram while a session is live.' },
        { cmd: '/workbench:supervise', desc: 'External crash/stall supervisor — relaunches and reconciles.' },
        { cmd: '/workbench:checkpoint', desc: 'Write a resume-from-this-file-alone SESSION_STATE.md now.' },
      ],
    },
    {
      group: 'Maturity & architecture',
      items: [
        { cmd: '/workbench:level status|up|down|<name>', desc: 'Recommend-only level change — shows the diff before confirming.' },
        { cmd: '/workbench:architecture view|drift', desc: 'View the C4 backbone, or diff authored intent against reality.' },
      ],
    },
    {
      group: 'Governance & insight',
      items: [
        { cmd: '/workbench:mc', desc: 'Mission Control — the single status dashboard.' },
        { cmd: '/workbench:doctor', desc: 'Health-check — drift, stale state, cap violations.' },
        { cmd: '/workbench:budget', desc: 'Token-spend tracking and governance.' },
        { cmd: '/workbench:score', desc: 'The loop’s expectancy/grade — net verified-value per task and per 100k tokens.' },
        { cmd: '/workbench:suggest', desc: 'Recommend-only idea surface — add, act, dismiss, clear.' },
      ],
    },
  ];

  WB.HOW_IT_WORKS = [
    { t: 'A session runs a /workbench:* command', d: 'task, dispatch, mesh start, whatever — same CLI whether you’re solo or on a team.' },
    { t: 'The CLI writes to the project’s own files', d: 'tasks/, decisions/, the event log — plain files under .claude/ and .workbench/. Nothing leaves the machine by default.' },
    { t: 'Dispatch spawns real engineer sessions', d: 'a claude-engineer or codex-engineer lane runs the task in a worktree, via the engineer subagent.' },
    { t: 'If the mesh is running, events mirror into a room', d: 'presence, chat, task handoffs — anything another connected session or device can usefully see.' },
    { t: 'This dashboard reads that log over HTTP on your LAN', d: 'it never originates state — only reflects it. Everything here also works from the CLI with no dashboard open at all.' },
  ];

  WB.GUIDES = [
    {
      id: 'setup-mesh', title: 'Setting up mesh',
      body: 'Turn a solo session into a coordinated team. Whoever runs start becomes the host — the mesh daemon then keeps running independently of that session.',
      steps: [
        { cmd: '/workbench:mesh start --lan', note: 'or --local to keep it to this machine only. Prints the bind address and a one-time local_token.' },
        { cmd: '/workbench:mesh invite --role worker', note: 'creates a short-lived, role-scoped token — shown exactly once.' },
        { cmd: '/workbench:mesh connect <url> <token>', note: 'run on the joining machine, using the token you just copied.' },
        { cmd: '/workbench:mesh who', note: 'confirms who’s connected — or just check Host → Devices here.' },
      ],
    },
    {
      id: 'invite-device', title: 'Inviting a device',
      body: 'Invites are role-scoped (worker, operator, observer) and short-lived by design — the raw token is shown once and never re-displayed.',
      steps: [
        { cmd: '/workbench:mesh invite --role worker --ttl 30m', note: 'or use Host → Enrollment here — same action, same one-time token.' },
        { cmd: '(share the token out-of-band)', note: 'Slack, a terminal you’re both in — never through the mesh itself.' },
        { cmd: '/workbench:mesh revoke-device <device>', note: 'one-way — re-enrollment needs a fresh invite. Use it the moment a token goes to the wrong place.' },
      ],
    },
    {
      id: 'orphaned-host', title: 'Recovering an orphaned host',
      body: 'Orphaned means the daemon is alive but the session that started it is gone — a real, legitimate state, not a crash. Coordination keeps working; only the host’s own lead purpose goes stale.',
      steps: [
        { cmd: '/workbench:lead adopt', note: 'in any connected session, to pick the stale lead purpose back up.' },
        { cmd: '/workbench:mesh status', note: 'confirms the daemon is still serving — it usually is.' },
        { cmd: '/workbench:mesh start --lan', note: 'only needed if the host MACHINE itself went down — there is no failover, see Host.' },
      ],
    },
    {
      id: 'change-level', title: 'Changing your level',
      body: 'Levels are recommend-only — a preview here never changes what the Board or anyone else sees. Only a session running the real command applies it, and even that confirms first.',
      steps: [
        { cmd: '/workbench:level status', note: 'shows the current level and whether any dial has been overridden.' },
        { cmd: '/workbench:level up', note: 'or down, or a level name directly — shows the diff, asks to confirm, never forces it.' },
      ],
    },
  ];

  WB.FAQ = [
    { q: 'Can I approve a decision from my phone?', a: '/workbench:remote surfaces decisions via Telegram; the dashboard’s Approve/Deny here mirrors the same lifecycle transition as /workbench:decision resolve.' },
    { q: 'Do crew agents show up on the mesh?', a: 'No — only leads connect. A lead’s crew (team + subagents) is visible via a pull-based snapshot on its session view, never streamed.' },
    { q: 'Is this safe to run outside my LAN?', a: 'No — LAN mode is TLS-encrypted with a self-signed cert pinned by fingerprint, bearer-token auth, trusted-LAN only, by design. There’s no CA-trusted cert and no public exposure.' },
    { q: 'What happens at the in-review cap?', a: 'The loop stops picking new work at cap−3 and drains reviews first — see Board for the live count.' },
    { q: 'Can two people run mesh start at once?', a: 'One host at a time. The second session should join as a device via invite instead of starting its own daemon.' },
    { q: 'What’s the difference between park and suggest?', a: 'park commits out-of-scope work as a real backlog task; suggest add is a non-committed “maybe later” idea — dismiss makes it permanent, clear just deletes the file for now.' },
  ];
})(window.WB);
