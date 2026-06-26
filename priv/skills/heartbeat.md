---
name: heartbeat
description: Self-scheduling pattern for proactive agents — check sources, act on findings, schedule next check
tags:
  - autonomy
  - monitoring
  - proactive
---

# Heartbeat: Proactive Agent Pattern

**Overview**
You've been activated by a scheduled heartbeat. Your job: check your configured sources, act on findings, then schedule your next activation before going idle.

---

## Step 1: Check Your Memory

Before doing anything, check your agent memory for pending state from previous runs:
- search_memories(scope: 'agent', query: 'pending') — find pending approvals, in-progress tasks
- If you have pending approvals, check if the user has responded (look at recent messages)
- If you have in-progress tasks, resume where you left off

---

## Step 2: Execute Your Heartbeat Instructions

Follow your heartbeat_instructions (included in the trigger prompt). Typical patterns:

**Error monitoring:**
1. Fetch recent errors from your configured source (web_fetch)
2. Check memory for already-processed error IDs
3. For new errors: assess severity, investigate, fix if actionable
4. Store processed IDs in memory

**Content curation:**
1. Fetch new items from your configured sources (web_fetch)
2. Check memory for already-processed item IDs
3. Evaluate relevance, produce summaries for interesting items
4. Store processed IDs in memory

**General:**
- Process at most 3 items per heartbeat to control costs
- If a task requires user input, use request_approval and save context to memory
- If a task fails after 2 attempts, store the failure in memory and skip it next time

---

## Step 3: Schedule Your Next Activation

ALWAYS schedule your next heartbeat before going idle, using create_job:

create_job(name: "heartbeat", schedule_type: "one_time",
  scheduled_at: "<ISO8601 UTC datetime>",
  trigger_prompt: "<your heartbeat instructions>")

**Timing guidelines:**
- Found actionable items → schedule in 30-60 minutes (follow up soon)
- Nothing found → schedule in 6-24 hours (back off to save costs)
- Hit an API rate limit → schedule in 2+ hours
- Completed a fix → schedule in 1 hour (verify it worked)
- Requested approval → schedule in 1 hour (check if user responded)

---

## Core Rules

- **Always schedule next heartbeat** — if you forget, the safety net will re-seed in 15 min, but don't rely on it
- **Use agent memory** — it persists across heartbeats. Store processed IDs, task state, failure counts
- **Respect budgets** — check at most 3 items per heartbeat. Don't run expensive operations on every check
- **Stop on approval requests** — after calling request_approval, save context to memory and stop
- **Report to user** — when you complete something significant, post a summary
