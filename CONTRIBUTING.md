# Contributing to Magus

Thanks for your interest in contributing! Magus is the open core of an
AI chat platform built with Phoenix/LiveView and Ash. This guide covers how to
get set up, the conventions we follow, and how to submit changes.

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Open core vs. cloud

This repository (`magus`) is the **open core**, licensed under
[Apache-2.0](LICENSE). The commercial hosted edition (**Magus Cloud**) lives in a
separate, private repository and depends on this one; it adds billing/Stripe and
marketing/CMS on top.

Please keep contributions here **edition-neutral**: core code must not depend on
commercial billing. Usage *governance* (spend caps, plans, limits) is open and
lives in `Magus.Usage`; commercial *billing* does not belong in this repo. When
core needs a behaviour that the cloud edition specializes, it goes through a
config-driven seam (an `Application.get_env` adapter with a no-op/identity
default), not a direct reference.

## Getting started

Prerequisites: Elixir/Erlang (see `.tool-versions` or `mix.exs`), PostgreSQL 16+
with the `vector` extension, Node 22+ (for the SvelteKit frontend), and a running
FalkorDB (for the Super Brain graph features). A `docker-compose.selfhost.yml` is
provided to bring up the data services.

```bash
mix setup          # deps + database + assets
mix phx.server     # or: iex -S mix phx.server
```

Run `mix magus.doctor` to check your configuration.

## Development workflow

- **Tests:** `mix test`. Please add tests for new behaviour and bug fixes.
- **Before opening a PR:** `mix precommit` (compiles with warnings-as-errors,
  checks formatting, runs the suite).
- **Formatting:** `mix format` (CI enforces it).
- **Migrations:** generate with `mix ash.codegen` after schema changes; never
  hand-edit applied migrations.
- **Localization:** German uses informal address (du/dein); edits go in
  `priv/gettext/de/LC_MESSAGES/`.

See [CLAUDE.md](CLAUDE.md) / [AGENTS.md](AGENTS.md) for a deeper tour of the
architecture and conventions.

## Submitting changes

1. Fork the repository and create a topic branch from `main`.
2. Make your change with tests; keep commits focused and the history readable.
3. Ensure `mix precommit` passes.
4. **Sign off your commits** (see DCO below): `git commit -s`.
5. Open a pull request describing the change and linking any related issue.
   Fill out the PR template.

Small, well-scoped PRs are easiest to review. For large or architectural changes,
please open an issue first to discuss the approach.

## Developer Certificate of Origin (DCO)

We use the [Developer Certificate of Origin](https://developercertificate.org/)
to certify that you wrote, or otherwise have the right to submit, the code you
contribute. Add a `Signed-off-by` line to every commit:

```
Signed-off-by: Your Name <your.email@example.com>
```

`git commit -s` adds this automatically (configure `git config user.name` and
`git config user.email` first). By signing off, you certify the following:

```
Developer Certificate of Origin
Version 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I have the right
    to submit it under the open source license indicated in the file; or
(b) The contribution is based upon previous work that, to the best of my
    knowledge, is covered under an appropriate open source license and I have
    the right under that license to submit that work with modifications,
    whether created in whole or in part by me, under the same open source
    license (unless I am permitted to submit under a different license), as
    indicated in the file; or
(c) The contribution was provided directly to me by some other person who
    certified (a), (b) or (c) and I have not modified it.
(d) I understand and agree that this project and the contribution are public and
    that a record of the contribution (including all personal information I
    submit with it, including my sign-off) is maintained indefinitely and may be
    redistributed consistent with this project or the open source license(s)
    involved.
```

## License

By contributing, you agree that your contributions will be licensed under the
[Apache License 2.0](LICENSE).

## Security

Please do **not** file security vulnerabilities as public issues. See
[SECURITY.md](SECURITY.md) for how to report them privately.
