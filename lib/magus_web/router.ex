defmodule MagusWeb.Router do
  @moduledoc """
  OSS application router.

  Composes the open-core pipelines and routes defined in `MagusWeb.CoreRouter`.
  `magus_cloud` ships its own router that invokes the same `core_pipelines/0`
  and `core_routes/0` and then appends cloud-only pipelines and scopes (Stripe,
  checkout/portal, marketing/CMS, billing admin).
  """
  use MagusWeb, :router
  use MagusWeb.CoreRouter

  core_pipelines()
  core_routes()

  # The SPA is the primary UI: every remaining browser GET (including `/`) serves
  # the SvelteKit shell, and client-side routing takes over. Anonymous visitors
  # are redirected to sign-in by `require_auth_browser`. This catch-all lives in
  # the composing router so each edition owns its root — `magus_cloud` places a
  # public marketing landing ahead of its own catch-all.
  scope "/", MagusWeb do
    pipe_through [:browser, :require_auth_browser]

    get "/*path", NextUiController, :spa
  end
end
