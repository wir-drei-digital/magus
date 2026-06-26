---
title: How RAG Works
description: How Magus uses your data to give agents better answers
order: 1
---

# How RAG Works

RAG stands for Retrieval-Augmented Generation. In plain terms: instead of relying only on what the AI was trained on, your agent can search your own data and include relevant information when it answers you.

## What Magus Does With Your Content

When you upload a file, connect a data source, or add a web source, Magus processes the content in the background:

1. The content is split into small, overlapping chunks.
2. Each chunk is converted into a numerical representation (an embedding) that captures its meaning.
3. These embeddings are stored and indexed for fast similarity search.

When you ask your agent a question, it searches your indexed content for the chunks most relevant to your question and includes them as context before generating a response. This happens automatically.

## What This Means in Practice

- Your agent can answer questions about documents you've uploaded, even if the AI was never trained on that content.
- It can reference specific details from long PDFs, web pages, or logs rather than guessing.
- Connected sources like RSS feeds or web sources stay up to date, so your agent's answers reflect current information.

The agent does not read every file every time. It only retrieves the chunks that are relevant to your current question, which keeps responses fast and focused.
