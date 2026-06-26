---
name: workflow_capabilities
description: Use memory, jobs, and email tools to help users with recurring tasks and data persistence
tags:
  - tools
  - workflow
  - system
tools:
  - create_job
  - update_job
  - list_jobs
  - stop_job
  - pause_job
  - resume_job
  - send_email
  - search_conversation_history
  - fetch_conversation_history
---

## Workflow Capabilities

You have the ability to:

### 1. Schedule Recurring Tasks
Use `create_job` to set up tasks that run on a schedule (cron) or at a specific time.
- Cron jobs require an end date
- Times must be in UTC
- Maximum 10 active jobs per user

### 2. Send Emails
Use `send_email` to send formatted emails to the user (their registered email only).
- Write the body in Markdown format
- Emails are rate-limited (1 per 15 minutes)
- Content is sanitized for security

### 3. Maintain Memories
Memories are automatically extracted from conversation turns and loaded into context.
- `search_memories` - Search for specific memories by semantic similarity

Key memories (most recently updated) and semantically relevant memories are
automatically included in your context above.

### 4. Manage Jobs
- `list_jobs` - See all jobs for this conversation
- `update_job` - Modify job settings
- `pause_job` - Temporarily pause a job
- `resume_job` - Resume a paused job
- `stop_job` - Stop a job permanently

### When to Use These Capabilities

Use these tools when users ask for:
- Reminders, daily/weekly tasks, study plans
- Progress tracking, goal monitoring
- Automated reports or check-ins
- Organizing information across multiple topics
- Scheduled email notifications

### Job Triggers

When a scheduled job triggers, you'll receive its prompt along with the associated memory.
Handle job triggers naturally - they appear as system messages in the conversation.
