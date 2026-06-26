---
name: coding
description: Execute code, build projects, and work with files in the sandbox
tags:
  - coding
  - sandbox
  - python
tools:
  - run_code
  - exec_command
  - install_packages
  - sandbox_write_file
  - sandbox_read_file
  - sandbox_edit_file
  - sandbox_search
  - sandbox_list_files
  - sandbox_download_file
  - start_service
---

# Coding & Sandbox

You have access to a persistent sandbox environment for code execution. Follow these patterns for best results.

## Tool Sequence

Choose the right workflow based on what you're doing:

**Creating a new file:**
1. `sandbox_write_file` — write the complete file
2. `run_code` or `exec_command` — execute/compile it

**Editing an existing file:**
1. `sandbox_read_file` — read the file (with line numbers) to see current contents
2. `sandbox_edit_file` — make targeted search-and-replace edits
3. `run_code` or `exec_command` — test the changes

**Finding code across files:**
1. `sandbox_search` — grep for a pattern across the workspace
2. `sandbox_read_file` (with `start_line`/`end_line`) — read context around matches

**IMPORTANT: Never rewrite an entire file to change a few lines.** Use `sandbox_edit_file` for targeted modifications. This is faster, uses fewer tokens, and avoids accidentally changing unrelated code.

## Key Tools

| Tool | Purpose |
|------|---------|
| `run_code` | Execute Python code (working dir: /workspace) |
| `exec_command` | Run shell commands (ls, gcc, pdflatex, npm, etc.) |
| `install_packages` | Install Python packages via uv |
| `sandbox_write_file` | Create a new file or replace all content |
| `sandbox_read_file` | Read file contents with line numbers (supports line ranges) |
| `sandbox_edit_file` | Search-and-replace edit on an existing file |
| `sandbox_search` | Grep for a pattern across workspace files |
| `sandbox_list_files` | List files in a directory |
| `start_service` | Start a web server/service (returns preview URL) |

## File Editing

Use `sandbox_edit_file` for all modifications to existing files. The workflow is:

1. **Read first**: `sandbox_read_file` shows line-numbered output like `  1| def main():`. Use this to identify the exact code to change.
2. **Edit with exact match**: The `old_string` must match the file contents exactly, including indentation and whitespace.
3. **Verify**: Run the code or read the file again to confirm the edit worked.

Tips:
- If `old_string` matches multiple locations, include more surrounding lines to make it unique, or set `replace_all: true`.
- Use `sandbox_read_file` with `start_line`/`end_line` to zoom into a specific section of a large file.
- Use `sandbox_search` to find where something is defined before editing.

## Preinstalled Packages

The sandbox comes with these packages ready to use — no need to call `install_packages` for them:

**Python (3.13):** numpy, pandas, matplotlib, seaborn, pillow, requests, weasyprint, python-docx, openpyxl

**System tools:** Node.js, npm, curl, git, build-essential (gcc, make, etc.)

**LaTeX:** texlive-latex-base, texlive-latex-recommended, texlive-fonts-recommended, texlive-latex-extra, texlive-bibtex-extra, biber

Only use `install_packages` for packages not listed above.

## Important Rules

- **Always call `sandbox_download_file` BEFORE referencing a file in your message.** The tool returns a download URL — only after you have that URL can you include it as a link or image in your response. Never promise a download link without calling the tool first.
- Use `sandbox_read_file` only when YOU need the file contents (e.g., to analyze CSV output, check generated code, etc.).
- **Never start servers with exec_command** — use `start_service` instead. Long-running commands in exec_command will time out.
- The sandbox persists between messages — installed packages, files, and state carry over.
- Network access is restricted to package registries (PyPI, npm, apt repos, GitHub).

## Common Patterns

### Data Analysis
```
1. run_code: load data with pandas, analyze, save chart to /workspace/chart.png
2. sandbox_download_file: download chart.png — get the URL first, then embed it as an image in your response
```

### Document Generation (Simple PDF)
```
1. run_code: generate PDF using weasyprint (HTML + CSS), save to /workspace/output.pdf
2. sandbox_download_file: download output.pdf so the user can access it
```

### Document Generation (LaTeX)
```
1. sandbox_write_file: write .tex file to /workspace/document.tex
2. exec_command: "cd /workspace && pdflatex document.tex"
3. sandbox_download_file: download document.pdf so the user can access it
```

### Web Application
```
1. sandbox_write_file: write HTML/JS/Python files to /workspace
2. start_service: start the web server (returns preview URL with iframe)
```

### Iterative Bug Fixing
```
1. run_code or exec_command: run the code, observe the error
2. sandbox_search: find the relevant code (if unsure where it is)
3. sandbox_read_file: read the file with line numbers
4. sandbox_edit_file: fix the bug with a targeted edit
5. run_code or exec_command: verify the fix
```

## start_service Usage

The `command` + `args` must form a complete, runnable command. The service must actually listen on the specified `port`.

**CRITICAL**: `args` are the command-line arguments — they are NOT just the port number. Include ALL arguments needed to run the service.

| Scenario | command | args | port |
|----------|---------|------|------|
| Python app | `"python3"` | `["app.py"]` | 5000 |
| Python http.server | `"python3"` | `["-m", "http.server", "8000"]` | 8000 |
| Node.js | `"node"` | `["server.js"]` | 3000 |
| Flask | `"python3"` | `["-m", "flask", "run", "--host=0.0.0.0", "--port=5000"]` | 5000 |
| Static files (npx) | `"npx"` | `["serve", "-l", "3000", "/workspace"]` | 3000 |

**Wrong**: `command: "python3", args: ["8000"], port: 8000` — this runs `python3 8000` which tries to execute a file named "8000".

**Right**: `command: "python3", args: ["-m", "http.server", "8000"], port: 8000` — this runs `python3 -m http.server 8000`.

## Output Handling

After `run_code` or `exec_command`, the response includes:
- `stdout` / `stderr` — command output
- `workspace_files` — list of ALL files in /workspace with name, path, and size

Interpret results for the user in natural language. Don't dump raw output — explain what happened and highlight key findings.
