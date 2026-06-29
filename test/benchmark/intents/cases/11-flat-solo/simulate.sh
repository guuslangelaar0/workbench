#!/usr/bin/env bash
for t in "Subscriptions" "Invoices" "Refunds" "Webhook handling"; do
  bash "$ROOT/scripts/task-new.sh" --target . --state backlog --title "$t" >/dev/null 2>&1
done
