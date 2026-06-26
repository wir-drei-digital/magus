---
name: council
description: Get multiple expert perspectives on a plan or question by spawning sub-agents with diverse viewpoints
tags:
  - planning
  - decision-making
  - perspectives
tools:
  - list_models
  - spawn_sub_agent
  - await_sub_agents
---

# Council: Multi-Perspective Advisory Panel

**Overview**
Spawn 3 sub-agents as council members, each with a distinct perspective on the user's question or plan. Collect their independent opinions, then synthesize a structured overview with consensus, disagreements, and a recommendation.

---

## Step 1: Understand the Question

Parse the user's topic from their message. If the question is clear and specific enough for advisors to reason about, proceed immediately. Only ask ONE clarifying question if the topic is truly too vague to act on.

**Good to go:** "Should we use Redis or PostgreSQL for our caching layer?"
**Needs clarification:** "/council" with no further context

---

## Step 2: Choose 3 Perspectives

Analyze the topic and select 3 **contrasting** viewpoints that provide the most useful coverage. The perspectives should create productive tension — if all three would say the same thing, pick more diverse angles.

**Example perspective archetypes** (use as inspiration, not a fixed list):

| Perspective | Focus |
|-------------|-------|
| The Pragmatist | Feasibility, cost, effort, proven solutions, risks |
| The Innovator | Creative approaches, emerging trends, unconventional ideas |
| The Critic | Stress-tests assumptions, finds weaknesses, worst-case scenarios |
| The User Advocate | End-user experience, accessibility, simplicity |
| The Strategist | Long-term thinking, big picture, competitive landscape |
| The Specialist | Deep domain expertise specific to the topic |
| The Minimalist | Simplest possible solution, cut scope, do less |
| The Historian | Precedent, what has worked before, lessons from similar situations |

Pick perspectives that fit the domain. A cooking question might get "The Traditionalist", "The Experimentalist", and "The Nutritionist". A business decision might get "The CFO", "The Customer", and "The Competitor".

Give each council member a memorable name that reflects their perspective (e.g., "The Pragmatic Engineer" rather than just "Advisor 1").

---

## Step 3: Select Models

Call `list_models` with `mode: "council"` to discover available models. This returns one top model per provider (e.g., Anthropic, Google, OpenAI). Pick **3 different models from different providers** to get genuine diversity in reasoning style — this is where much of the council's value comes from.

**Fallback:** If the tool is unavailable or returns fewer than 3 options, use the user's current model for all council members. Different perspectives via system prompts still provide value.

---

## Step 4: Spawn Sub-Agents

Use `spawn_sub_agent` in **inline mode** for each council member. Craft a tailored system prompt per perspective using this template:

```
You are [Name], a [perspective] advisor serving on a council.

Your role is to evaluate the following topic strictly from your viewpoint:
[One sentence describing what this perspective prioritizes and how it thinks.]

Guidelines:
- Be concise and opinionated. Take a clear position.
- Do NOT hedge or try to cover all angles — the other council members handle that.
- Challenge assumptions where your perspective demands it.

Structure your response as:
1. **Your Assessment** (2-3 focused paragraphs from your viewpoint)
2. **What Others Will Miss** (1-3 key risks or opportunities only your perspective reveals)
3. **Bottom Line** (Your single clearest recommendation in 1-2 sentences)
```

Set the `objective` to the user's question/plan. Pass `model_key` from `list_models` results and `system_prompt` with the perspective instructions.

Spawn all 3 in sequence (the tool handles queuing), then proceed to await.

---

## Step 5: Await Results

Call `await_sub_agents` to wait for all 3 council members to complete. The tool automatically finds all sub-agents spawned from this conversation — no need to pass task IDs.

---

## Step 6: Synthesize & Present

Present the council's findings in this structure:

```markdown
## Council Overview

[One sentence restating the question. One sentence explaining why these 3 perspectives were chosen.]

### [Color Emoji] [Council Member Name]
[Summary of their position and key arguments. Preserve their strongest points
and sharpest insights — don't water them down.]

### [Color Emoji] [Council Member Name]
[Same format]

### [Color Emoji] [Council Member Name]
[Same format]

## Consensus
[What all three agree on. If there is genuine consensus on certain points,
highlight it — this carries weight.]

## Key Disagreements
[Where they diverge and WHY they diverge — trace disagreements back to
differing priorities or assumptions, not just different conclusions.]

## Synthesis & Recommendation
[Your own balanced recommendation weighing all perspectives. Be decisive —
don't just summarize, take a position. Explain which perspective you weight
most heavily for this specific situation and why.]
```

Use distinct color emojis to visually distinguish members (e.g., 🔵 🟢 🔴).

**Adapt the format to the situation.** A simple question might not need a full disagreements section. A complex strategic decision might warrant more detail in the synthesis.

---

## Core Rules

- **Diversity is the point.** If your 3 perspectives would give similar answers, you chose poorly. Rethink.
- **Opinionated > Balanced.** Each council member should take a clear position. The synthesis is where balance happens.
- **Don't filter.** Present uncomfortable or contrarian opinions faithfully. The critic's job is to criticize.
- **Be decisive in synthesis.** The user asked for help deciding. End with a clear recommendation, not "it depends."
- **Keep it scannable.** Use formatting, bold key points, keep summaries tight. The user shouldn't have to read 2000 words to get the insight.
