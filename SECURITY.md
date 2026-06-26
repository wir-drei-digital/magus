# Security Policy

We take the security of Magus seriously. Thank you for helping keep Magus and
its users safe.

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
discussions, or pull requests.**

Instead, report them privately through one of:

1. **GitHub private vulnerability reporting** (preferred) — open the
   [Security tab](https://github.com/wir-drei-digital/magus/security) of this
   repository and click **"Report a vulnerability"**. This keeps the report
   private to the maintainers until a fix is released.
2. **Email** — **security@magus.digital**, optionally encrypted.

Please include as much of the following as you can:

- The type of issue (e.g. injection, authentication bypass, SSRF, secrets
  exposure, privilege escalation).
- Affected component(s) and file path(s).
- Step-by-step instructions to reproduce, and a proof-of-concept if possible.
- The impact, and any suggested remediation.

You should receive an acknowledgement within **3 business days**. We will keep
you informed of progress toward a fix and may ask for additional detail.

## Disclosure Policy

We follow coordinated disclosure. Once a report is received we will:

1. Confirm the issue and determine the affected versions.
2. Develop and test a fix.
3. Release the fix and publish a security advisory crediting the reporter
   (unless you prefer to remain anonymous).

Please give us a reasonable window to address the issue before any public
disclosure.

## Scope

This policy covers the open-core Magus codebase in this repository. The hosted
commercial edition (Magus Cloud) and its billing/Stripe integration are operated
separately; vulnerabilities specific to the hosted service can be reported
through the same channels above.

## Operating Magus securely

If you self-host Magus, a few essentials:

- Set strong, unique values for `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`, and
  `INTEGRATION_ENCRYPTION_KEY` (never reuse the development defaults).
- Keep `DATABASE_URL`, provider API keys, and other secrets out of version
  control; supply them via environment variables.
- Run behind TLS and keep your deployment and dependencies up to date.
- Review `mix magus.doctor` output before going live.

See the [README](README.md) for the full self-host setup.
