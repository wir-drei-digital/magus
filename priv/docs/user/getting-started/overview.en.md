---
title: Overview
description: Get started with Magus - your AI-powered assistant
order: 1
---

# Getting Started with Magus

Magus is an AI-powered chat platform that lets you have rich conversations with AI assistants. Whether you need help with writing, coding, research, or creative tasks, Magus provides a flexible environment where you can customize your AI experience to fit your workflow.

## Core Concepts

At the heart of Magus are **conversations**. Each conversation runs its own AI agent, maintaining context throughout your interaction. You can have multiple conversations running simultaneously, each with different settings and purposes. Conversations support markdown rendering, file attachments, and real-time streaming responses.

**Agents** are the AI personalities behind your conversations. Every conversation uses a default agent, but you can create custom agents with specific system prompts, tool configurations, and integrations. Custom agents are ideal for recurring tasks, for example, a code review agent with access to your repository logs, or a research agent connected to RSS feeds.

**Prompts** help you guide AI behavior consistently. System prompts act as personas that shape how the agent responds, while user prompts are reusable templates for common tasks. You can browse and share prompts through the public prompt library, or keep your own collection private. When you activate a system prompt on a conversation, it's prepended to every message the agent sees.

## Choosing Models

Magus supports multiple AI models from various providers. You can select different models for different tasks: one for chat, another for image generation, and another for video generation. Models vary in capability, speed, and cost. You can change your model at any time, even mid-conversation, and each conversation (or thread) can use a different model independently.

## Extending Your Workflow

**Threads** let you branch off from any message to explore a tangent without derailing the main conversation. The thread inherits context up to the branch point and then runs independently. This is useful for diving deep into a subtopic while keeping the main conversation focused. See [Threads](../features/threads.en.md) for details.

**Data Sources** connect external data streams like application logs and RSS feeds to your agents. Your agent can search ingested data, monitor for errors, and alert you when something needs attention. See [Data Sources](../knowledge/data-sources.en.md) for details.

**Integrations** let you connect Magus to external services. The REST API integration lets you embed Magus agents into your own applications, sending messages and receiving responses programmatically. See [API Integration](../integrations/api-integration.en.md) for details.
