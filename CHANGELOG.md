# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Community health files: `CONTRIBUTING.md` (with DCO sign-off), `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, issue/PR templates, and this changelog.

## [0.1.0] - 2026-06-26

Initial public release of Magus open core (Apache-2.0).

### Added

- AI chat with agentic tool execution (Jido agents, ReAct loop), streaming
  responses, and multi-agent orchestration.
- Prompt library with pgvector semantic search; Brain (markdown pages with
  wikilinks) and Super Brain knowledge graph.
- Files with chunking/embeddings, Memory, Workspaces with shared access grants,
  collaborative Plan/Tasks, and a SvelteKit workbench frontend.
- Usage governance (`Magus.Usage`): spend caps, plans, and limit enforcement,
  decoupled from commercial billing via config-driven adapter seams.
- Model catalog with provider routing; self-host setup via
  `docker-compose.selfhost.yml` and a `mix magus.doctor` configuration check.

[Unreleased]: https://github.com/wir-drei-digital/magus/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/wir-drei-digital/magus/releases/tag/v0.1.0
