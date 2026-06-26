---
title: Agent Tools & Models
description: Configure which tools your agent can use and which AI model it runs on
order: 3
---

# Agent Tools & Models

Tools give your agent capabilities beyond simple text generation. When you enable a tool category, the agent can use those tools during a conversation whenever they are helpful. You can also choose which AI model powers your agent.

## Tool categories

### Web

Lets the agent search the internet and fetch content from URLs. Useful for research tasks, looking up current information, and reading documentation or articles that the model was not trained on.

### Code

Gives the agent access to a sandboxed code execution environment. The agent can write and run Python code, install packages, read and write files, and start services. This is powerful for data analysis, automation scripts, and any task that benefits from real computation rather than guessing.

### Memory

Lets the agent remember information across conversations. It can store facts, preferences, and observations, then retrieve them later when relevant. Great for agents you use regularly and want to "know" you over time.

### Files

Lets the agent search through documents you have uploaded. When you attach files to a conversation or have a collection connected, this tool allows the agent to find and read relevant sections rather than loading everything at once.

### Skills

Gives the agent access to a library of specialized instruction sets for specific task types, such as writing poetry, generating structured data, or following a particular workflow. The agent loads the relevant skill automatically when the task matches.

### Tasks

Lets the agent create and manage tasks in the built-in task manager. Useful for agents that help you track work, break projects into steps, and follow up on progress.

### Integrations

Lets the agent interact with external services you have connected, such as searching entries from a data source or checking the status of an integration. Requires at least one integration to be configured on the agent.

## Enabling and disabling tool categories

In the agent editor, you will find a **Tools** section listing each category with a toggle. Turn a category on or off to grant or revoke that capability for the agent.

As a general rule: enable only the tools the agent actually needs. A focused tool set reduces the chance of the agent reaching for the wrong tool and makes its behavior more predictable.

## Choosing a model

In the agent editor, open the **Model** section. You can:

- **Auto-select**: Let the agent choose the best model for each task based on the chat mode and what is being asked. This is a good default if your agent handles a variety of tasks.
- **Specific model**: Pin the agent to a particular model. Use this when you need consistent behavior, predictable costs, or a model with specific capabilities (such as one with very long context or strong reasoning).

You can set separate models for chat, image generation, and video generation if your agent uses multiple modes.

## Max iterations

The **Max iterations** setting controls how many tool-use cycles the agent can go through in a single response. Each iteration involves the agent calling a tool and reading the result before deciding what to do next.

A higher limit allows more complex tasks (for example, researching several sources before answering) but also means longer wait times and higher resource use. The default is suitable for most tasks. Raise it only if your agent regularly needs to chain many steps together.
