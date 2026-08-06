---
title: Sandbox & Services
description: Run code, install packages, and start web services with a live preview in a secure sandbox
order: 10
---

# Sandbox & Services

The sandbox gives the AI a secure environment to write and run code, install packages, read and write files, and start web services. Everything runs in an isolated container, so nothing affects your local machine.

## Code execution

When the AI needs to compute something, analyze data, or test a script, it can run code in the sandbox. You will see the code it runs and the output directly in the conversation. Supported tasks include:

- Running code in various programming languages. The agent typically uses python if not requested otherwise.
- Reading and writing files inside the sandbox
- Downloading generated files (PDFs, images, CSVs, etc.)
- Host a web application

The sandbox starts automatically the first time the AI runs code in a conversation. It stays active for 15 minutes after the last use, then suspends to save resources. It wakes up automatically the next time it is needed.

## Starting a service

The AI can start web services in the sandbox, such as a Flask app, a Node.js server, or any process that listens on a port. When a service starts, a service pane with a live preview opens beside the chat.

The service pane shows:

- A live preview of the running service in an embedded frame
- A **Reload** button to refresh the preview
- An **Open** button to open the service in a new browser tab

You can keep chatting with the AI while the service runs. Ask it to make changes to the code, then click **Reload** in the pane to see the updated result.

## The service pane

The service pane works like other side panes (drafts, threads). It opens automatically when a service starts. If you close it, you can reopen it by clicking **View in Pane** on the service card in the message stream.

## Suspended services

When the sandbox suspends after 15 minutes of inactivity, the preview shows an error page instead of your service. Just continue the conversation: the sandbox wakes up automatically the next time the AI uses it, and you can ask the AI to start the service again.

## Limitations

- Each conversation has one sandbox. Starting a new service replaces the previous one.
- The sandbox suspends after 15 minutes of inactivity and terminates after 30 days.
- Files created in the sandbox are not permanent. Download anything you want to keep.
- The service preview URL is private and only accessible to you while logged in.
