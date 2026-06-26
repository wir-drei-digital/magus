# Local dependency patches

## `req_llm-surface-generation-id.patch`

Surfaces the provider's generation id (OpenRouter `gen-...`) on the streaming
response so we can reconcile authoritative usage/cost from
`GET /api/v1/generation` when the SSE stream omits usage.

- Adds `maybe_put_generation_id/2` to `ReqLLM.Provider.Defaults.default_decode_stream_event`,
  attaching `data["id"]` to the terminal metadata chunks (finish_reason / usage).
- Adds `ReqLLM.StreamResponse.provider_id/1`, mirroring `usage/1`.

Generated against pristine `req_llm` `v1.11.0`; applies cleanly there.

### Apply to a fork (manual PR — do NOT auto-open)

```bash
git clone https://github.com/agentjido/req_llm
cd req_llm && git checkout v1.11.0 && git switch -c surface-generation-id
git apply /path/to/magus/priv/patches/req_llm-surface-generation-id.patch
git commit -am "feat(stream): surface provider generation id in stream metadata"
# push to your fork, open the PR yourself
```

### Wire the fork into magus

Until the upstream PR merges, point `mix.exs` at the fork:

```elixir
# {:req_llm, "~> 1.11"},
{:req_llm, github: "<your-fork>/req_llm", branch: "surface-generation-id", override: true},
```

then `mix deps.get`. The app-side capture is defensive
(`function_exported?(ReqLLM.StreamResponse, :provider_id, 1)`), so it compiles
and runs on stock `req_llm` too — reconciliation just stays dormant until the
patched dep is active.
