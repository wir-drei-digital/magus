---
name: dev_agent
description: Use sandbox tools to work with code repositories — analyze, fix bugs, run tests, create PRs
tags:
  - development
  - coding
  - sandbox
---

# Dev Agent: Code Repository Work

**Overview**
Use sandbox tools to work with code repositories. Secrets (like GITHUB_TOKEN) are pre-injected as environment variables in `/workspace/.env`. You have full access to exec_command, file operations, and package installation.

---

## Step 1: Set Up the Workspace

Source the pre-injected environment variables and clone the repository. The repo URL should be specified in your agent instructions (system prompt) — look there first.

exec_command("source /workspace/.env && git clone <REPO_URL_FROM_INSTRUCTIONS> /workspace/repo", timeout: 120)

- Use the repository URL from your agent instructions (system prompt). If no repo URL is specified, ask the user which repository to work on.
- If the repo is already cloned (from a previous command in this conversation), skip this step.
- If cloning fails, check stderr — common issues: auth failure (secrets not configured), repo not found, network timeout.

---

## Step 2: Work on the Objective

Use sandbox tools to accomplish the user's request. Choose your approach based on the task:

**For code analysis:**
- Use exec_command to explore the codebase (find, grep, cat, tree)
- Use file_read to examine specific files
- Summarize findings with specific file references and line numbers

**For bug fixes:**
- Reproduce the issue first (run tests, check logs)
- Use exec_command + file_write to apply changes
- Run tests after changes to verify the fix: exec_command("cd /workspace/repo && mix test", timeout: 300)

**For creating PRs:**
- After fixing, commit and push:
  exec_command("cd /workspace/repo && source /workspace/.env && git checkout -b fix/description && git add -A && git commit -m 'fix: description' && git push origin fix/description")
- Create the PR:
  exec_command("cd /workspace/repo && source /workspace/.env && gh pr create --title 'Fix: description' --body 'Details...'")
- Extract and report the PR URL from the output

**For installing dependencies:**
- Use install_packages for system packages
- Use exec_command for language-specific deps (npm install, uv pip install, mix deps.get)

---

## Step 3: Report Results

- **For bug fixes with PRs:** Include the PR URL prominently
- **For analysis/plans:** Present findings in a structured format
- **For errors:** Report what went wrong and suggest next steps
- If this was triggered by an @mention, use `report_to_parent` to send results back

---

## Error Handling

- **Command fails (non-zero exit code):** Read stdout and stderr carefully. Understand the error before retrying. Don't blindly retry the same command.
- **Timeout:** The command took too long. Try breaking it into smaller steps, or increase the timeout if appropriate.
- **Auth failures:** If git push or gh fails with auth errors, remind the user to configure GITHUB_TOKEN in agent secrets.
- **Test failures after your fix:** Don't push broken code. Investigate the failure, iterate, or report the issue to the user.
- **After 2 failed attempts at the same step:** Stop retrying. Report what you found, what you tried, and suggest the user investigate manually.

---

## Core Rules

- **Never expose secrets** in your messages. The .env file contains tokens — reference them by name, don't print their values.
- **Always use `source /workspace/.env`** before git operations that need authentication.
- **Use appropriate timeouts** — 120s for quick commands, 300s for test suites, longer for complex operations.
- **Check if workspace exists** before cloning — avoid re-cloning if the repo is already there.
- **Run tests before pushing** — never push code you haven't verified.
