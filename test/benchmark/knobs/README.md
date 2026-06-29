# Knob search candidates (BM-6)

`scripts/knob-search.sh` turns the conformance benchmark into an optimizer. It scores the
current plugin (the **baseline**) and every **candidate** here against the conformance
**train** set, ranks them, and proposes a winner — **recommend-only**: it prints the apply
command, it never mutates the plugin.

## What a knob is

Anything that shapes how the model reads the plugin and therefore which behavior fires:

- a command's or skill's `description` (the routing trigger),
- the scaffolded `CLAUDE.md` intent-routing table,
- a dial / level preset.

## Candidate layout

```
candidates/<name>/
  overlay/        files copied OVER a fresh plugin checkout (the knob change)
  note            (optional) one line describing what this candidate changes
```

The `overlay/` mirrors the plugin tree. To try an alternative Mission-Control trigger,
add `overlay/commands/mc.md`; to try a different routing table, add
`overlay/templates/full/CLAUDE.md.tmpl`. Only the files you want to change go in `overlay/`.

## Running

```sh
# free plumbing check (cannot discriminate candidates — simulate fakes correct behavior)
scripts/knob-search.sh --simulate

# real search (drives Opus via bench-intents; costs API tokens)
WB_BENCH=1 scripts/knob-search.sh
```

A candidate must **strictly** beat the baseline on train to win (ties keep the baseline —
we don't churn descriptions for noise). A strict winner is then validated on the reserved
**holdout** set; if it wins on train but drops on holdout it's flagged **overfit** and not
recommended (the Goodhart guard, design §5.4). When a winner is recommended, apply it by
hand and re-run the full suite + the expectancy gate before committing.
