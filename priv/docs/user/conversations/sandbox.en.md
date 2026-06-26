---
title: Sandbox & Services
description: Run code, install packages, start web services in a secure sandbox, and capture screenshots from the live preview to send to chat
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

The AI can start web services in the sandbox, such as a Flask app, a Node.js server, or any process that listens on a port. When a service starts, a **Service Preview** pane opens on the right side of the chat.

The service pane shows:

- A live preview of the running service in an embedded frame
- The service status (running, suspended, stopped, or error)
- A button to open the service in a new browser tab
- A reload button to restart the service

You can keep chatting with the AI while the service runs. Ask it to make changes to the code, and then click the reload button in the pane to restart the service with the updated code.

## The service pane

The service pane works like other side panes (drafts, threads). It opens automatically when a service starts and stays open as you navigate. If you close it, you can reopen it by clicking **View in Pane** on the service card in the message stream.

The pane state persists across page reloads. If you reload the page or navigate away and come back, the service pane reopens in its last state.

## Restarting a suspended service

When the sandbox suspends after 15 minutes of inactivity, the service pane shows a "suspended" status with a **Restart Service** button. Clicking it wakes the sandbox and restarts the service using the same command and configuration from when it was originally started.

You can also click the reload button in the pane header at any time to restart the service, even while it is running. This stops the current process and starts a fresh one.

## Taking screenshots

You can capture a screenshot of the service preview and send it to the chat. This is useful when you want to point out a visual issue, ask the AI about something on screen, or reference a specific part of the UI.

1. Click the **camera** icon in the service pane header. The button highlights to indicate you are in screenshot mode.
2. Click and drag to draw a rectangle over the area you want to capture.
3. An **Ask** button appears next to your selection. Click it to attach the screenshot to your next message.
4. The screenshot appears as a thumbnail badge in the chat input. Type your question or comment and send the message as usual.

To cancel, press **Escape** or click the camera icon again to exit screenshot mode. You can also dismiss an attached screenshot by clicking the **X** on its badge in the chat input.

The screenshot is included as an image in the message metadata, so the AI can see exactly what you are referring to.

## Limitations

- Each conversation has one sandbox. Starting a new service replaces the previous one.
- The sandbox suspends after 15 minutes of inactivity and terminates after 30 days.
- Files created in the sandbox are not permanent. Download anything you want to keep.
- The service preview URL is private and only accessible to you while logged in.
