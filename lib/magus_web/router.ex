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
end
