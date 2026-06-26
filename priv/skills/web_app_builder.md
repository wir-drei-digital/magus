---
name: web_app_builder
description: Build and run small web applications with live preview
enabled: true
tags:
  - web
  - development
  - preview
tools:
  - exec_command
  - sandbox_write_file
  - sandbox_read_file
  - sandbox_edit_file
  - sandbox_search
  - sandbox_list_files
  - sandbox_download_file
  - start_service
  - install_packages
---

# Web App Builder

You are helping the user build and run a small web application with a live preview URL.

## Preinstalled

The sandbox includes: Python 3.13, Node.js, npm, curl, git, build-essential.

Python packages already available: numpy, pandas, matplotlib, seaborn, pillow, requests, weasyprint, python-docx, openpyxl.

## Workflow

**Creating a new app:**
1. `sandbox_write_file` — Write application files
2. `exec_command` — Install dependencies (npm install, etc.)
3. `start_service` — Start the server with the correct port
4. Share the preview URL — it's private and only accessible to the user

**For downloadable files**, always call `sandbox_download_file` BEFORE referencing them in your response. The tool returns the URL — never include a download link without calling it first.

**Iterating on an existing app:**
1. `sandbox_read_file` — Read the file with line numbers
2. `sandbox_edit_file` — Make targeted edits
3. Restart the service if needed (stop + `start_service` again)

**Finding code across files:**
1. `sandbox_search` — Grep for a pattern across the workspace
2. `sandbox_read_file` (with `start_line`/`end_line`) — Read context around matches

**Never rewrite an entire file to change a few lines.** Use `sandbox_edit_file` for targeted modifications.

## Node.js / Express

```bash
# Setup
exec_command: "npm init -y && npm install express"
```

```javascript
// server.js
const express = require('express');
const app = express();
const port = process.env.PORT || 8080;

app.use(express.static('public'));
app.get('/', (req, res) => res.send('Hello World'));
app.listen(port, '0.0.0.0', () => console.log(`Listening on ${port}`));
```

```
start_service: name="web", command="node", args=["server.js"], port=8080
```

## Python / Flask

```python
# app.py
import os
from flask import Flask, send_from_directory
app = Flask(__name__)

@app.route('/')
def hello():
    return 'Hello World'

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port)
```

```
start_service: name="web", command="python3", args=["app.py"], port=8080
```

## Static Files Only

For simple HTML/CSS/JS sites, use Python's built-in HTTP server:

```
start_service: name="web", command="python3", args=["-m", "http.server", "8080"], port=8080
```

## Best Practices

- Always use port 8080. The sandbox only exposes port 8080 publicly.
- Always bind to `0.0.0.0` (not `localhost` or `127.0.0.1`) so the proxy can reach the service
- Read the `PORT` environment variable in your app (it's set to 8080 automatically by `start_service`)
- Create a `public/` directory for static assets (CSS, JS, images)
- For single-page apps, serve index.html for all routes
- Keep applications small and focused — the sandbox has limited resources
- Test the app works with `exec_command` + `curl localhost:8080` before using `start_service`
