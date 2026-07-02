#!/usr/bin/env bash
git init -q
mkdir -p api
cat > api/auth-refresh.js <<'JS'
// Mid-flight fixture for the continuity benchmark.
// The replay check is intentionally incomplete; the next session should resume it.
export function rotateRefreshToken(tokenFamily, presentedToken) {
  if (!tokenFamily || !presentedToken) throw new Error("missing token family");
  return {
    status: "todo",
    next: "implement replay detection for used refresh tokens",
  };
}
JS
bash "$ROOT/scripts/task-new.sh" --target . --state in-development --title "OAuth token refresh rotation" >/dev/null 2>&1
task="$(ls .claude/tasks/in-development/*oauth-token-refresh-rotation.md | head -1)"
cat > "$task" <<'MD'
# 0001 — OAuth token refresh rotation

**Status:** in-development
**Track:** auth
**Epic:** (none)
**Blocked-by:** (none)
**Repo(s):** api
**Estimate:** ~1 day
**Created:** 2026-07-02
**Verification:** run auth refresh-token unit tests and an integration scenario that rotates a refresh token once, rejects replay of the old token, and keeps the session valid with the new token

## Why
Refresh tokens must rotate after use so a stolen token cannot be replayed indefinitely.

## Acceptance criteria
- [ ] using a refresh token issues a new refresh token
- [ ] the previous refresh token is rejected after rotation
- [ ] a valid rotated token keeps the session alive
- [ ] audit notes record suspicious replay attempts

## Scenarios
- Happy path: a user refreshes once and receives a valid replacement token.
- Edge / negative: replaying the old token fails and records a replay attempt.

## Verification ladder
- [ ] engineer self-test
- [ ] automated unit tests
- [ ] integration
- [ ] human-readable evidence captured below

## Notes
2026-07-02 10:00 — owner: lead. Started OAuth token refresh rotation in `api/auth-refresh.js`; next step is implementing the token-family replay check.

## Verification evidence
(pending)
MD
tmp="$(mktemp)"
awk '
  /^\- \*\*Current focus:\*\*/ {
    print "- **Current focus:** mid-flight: implementing OAuth token refresh rotation (the load-bearing task)"
    next
  }
  /^\- \*\*Last commit per repo:\*\*/ {
    print "- **Last commit per repo:** initial checkpoint exists in git for task 0001"
    next
  }
  /^\- \*\*Build status:\*\*/ {
    print "- **Build status:** not run yet; `api/auth-refresh.js` is mid-flight"
    next
  }
  /^\- \*\*Blockers \/ decisions awaiting:\*\*/ {
    print "- **Blockers / decisions awaiting:** none recorded"
    next
  }
  /^\- \*\*Next action:\*\*/ {
    print "- **Next action:** continue task 0001 — OAuth token refresh rotation"
    next
  }
  { print }
' .claude/SESSION_STATE.md > "$tmp"
mv "$tmp" .claude/SESSION_STATE.md
git add . >/dev/null 2>&1
git -c user.name=Workbench -c user.email=workbench@example.com commit -m "chore: checkpoint oauth token refresh" >/dev/null 2>&1
