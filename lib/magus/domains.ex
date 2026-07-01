defmodule Magus.Domains do
  @moduledoc """
  The core Ash domain list, exported as a function for the open-core / cloud
  composition seam.

  `magus_cloud` composes its domain list explicitly as
  `Magus.Domains.core_domains() ++ cloud_domains()` and sets that as
  `config :magus, ash_domains, ...`. The OSS app uses `core_domains/0` directly.

  This is an independent literal (not read from `:magus, :ash_domains`) so cloud
  can compose against the true core set even when it overrides the app env with
  the combined list. The `Magus.DomainsTest` test asserts the combined
  `config/config.exs` `:ash_domains` equals this core list plus the cloud-only
  domains, so the two cannot drift.

  `Magus.Billing` is deliberately NOT listed here: it is the commercial
  billing edition's domain. The combined app's `:ash_domains` adds it back; the
  Phase 4 repo split (`magus-mxj5`) moves it to `magus_cloud` entirely.
  """

  @core_domains [
    Magus.Chat,
    Magus.Models,
    Magus.Accounts,
    Magus.Library,
    Magus.Files,
    Magus.Memory,
    Magus.Workflows,
    Magus.Usage,
    Magus.Sandbox,
    Magus.Agents,
    Magus.Integrations,
    Magus.Notifications,
    Magus.Drafts,
    Magus.Workspaces,
    Magus.Organizations,
    Magus.FeatureUsage,
    Magus.Plan,
    Magus.Knowledge,
    Magus.Brain,
    Magus.Workbench,
    Magus.SuperBrain,
    Magus.MCP
  ]

  @doc "The list of core Ash domain modules."
  @spec core_domains() :: [module()]
  def core_domains, do: @core_domains
end
