---
name: orchestrate
description: Break down complex work into tasks and delegate to specialized agents for parallel, asynchronous execution
tags:
  - planning
  - delegation
  - multi-agent
  - orchestration
---

# Orchestrate: Multi-Agent Task Delegation

**Overview**
Break a complex objective into concrete tasks, assign each to the best-suited agent, and let them work independently. You'll be notified as each agent completes their task, and you synthesize the results at the end.

This is **asynchronous orchestration** — unlike the council skill (which spawns agents and waits), you create a plan, delegate, and let the system notify you when work is done. This is better for tasks that take time (coding, research, design).

---

## Step 1: Understand the Objective

Parse what the user wants accomplished. If it's a single, focused task, you probably don't need orchestration — just do it yourself or delegate to one agent. Orchestration is for work that benefits from **parallel execution by different specialists**.

**Good for orchestration:** "Build a landing page with copy, design, and code"
**Not worth orchestrating:** "Write a function to parse CSV files" (just do it)

---

## Step 2: Check Available Agents

Your system prompt includes an "Available Agents" section listing agents you can delegate to. Review their capabilities and match tasks to strengths.

If no suitable agent exists for a task, do it yourself or tell the user they'd benefit from creating a specialist agent.

---

## Step 3: Create the Plan

Use `create_task` to build a task list. Each task should be:
- **A single, concrete deliverable** — not a phase or category
- **Assigned to a specific agent** using `assigned_to_agent_id`
- **Self-contained** — the assigned agent should be able to complete it without back-and-forth

```json
{"tasks": [
  {"title": "Write landing page copy", "description": "Hero section, features section, CTA. Tone: professional but approachable.", "assigned_to_agent_id": "<copywriter-agent-id>"},
  {"title": "Design landing page mockup", "description": "Modern, minimal design. Desktop and mobile layouts.", "assigned_to_agent_id": "<designer-agent-id>"},
  {"title": "Build landing page components", "description": "React components matching the design. Responsive, accessible.", "assigned_to_agent_id": "<coder-agent-id>"}
]}
```

**Task descriptions matter.** The assigned agent only sees the task title and description — write enough context that they can work independently.

---

## Step 4: Confirm with the User

Before delegating, present the plan to the user:

```markdown
## Orchestration Plan

I'll delegate this to 3 agents working in parallel:

1. **Write copy** → @copywriter
2. **Design mockup** → @designer
3. **Build components** → @coder

Each agent will work independently. I'll synthesize the results when everyone's done.

Shall I proceed?
```

Wait for confirmation. The user might want to adjust assignments, add tasks, or change scope.

---

## Step 5: Let Agents Work

Once the plan is created with task assignments, the system handles the rest automatically:

1. Each assigned agent gets an inbox notification (`:task_assigned` event)
2. Their triage sweep picks up the task
3. They work in their own conversations
4. When done, you receive a notification (`:agent_message` event)

**You don't need to stay active.** Your turn ends after creating the tasks. The notification system brings you back when agents complete.

**Important:** Before your turn ends, store your plan context in agent memory so your triage sweep can understand the orchestration when notifications arrive:

Use `set_memory` with key "active_plan" and value describing the objective, delegated tasks, and what to do when all complete.

---

## Step 6: Monitor Progress (Optional)

If the user asks for a status update, check your open tasks:
- **In progress** — agent is working on it
- **Blocked** — agent needs something (check the blocked_reason)
- **Done** — agent finished

You can also check via the task pane in the conversation UI.

---

## Step 7: Synthesize Results

When all delegated tasks are complete (you'll be notified for each one), review the results and synthesize:

```markdown
## Results

All 3 tasks are complete. Here's what was delivered:

### Copy (@copywriter)
[Summary of what was written, key decisions made]

### Design (@designer)
[Summary of the design, notable choices]

### Components (@coder)
[Summary of what was built, any technical decisions]

## Integration Notes
[How the pieces fit together, any gaps or conflicts between the deliverables, next steps]
```

---

## When to Use Orchestration vs Council

| Use | When |
|-----|------|
| **Orchestrate** | Work needs to be **done** — code written, designs created, research compiled |
| **Council** | You need **opinions** — perspectives on a decision, strategy review, plan critique |

Orchestrate produces deliverables. Council produces advice.

---

## Core Rules

- **Match agents to tasks.** Don't assign code to a copywriter. If no agent fits, do it yourself.
- **Write self-contained task descriptions.** The agent can't ask you follow-up questions during execution.
- **Confirm before delegating.** The user should approve the plan and assignments.
- **Don't over-orchestrate.** If the work is simple enough for one agent, just delegate directly without a full plan.
- **Synthesize, don't just relay.** When results come back, identify integration points, conflicts, and next steps — don't just paste the outputs together.
