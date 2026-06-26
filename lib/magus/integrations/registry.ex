defmodule Magus.Integrations.Registry do
  @moduledoc """
  Runtime registry of integration provider modules (the open-core seam).

  Core ships the built-in providers (`builtins/0`). Cloud or external code can
  `register/2` additional providers at runtime, à la `ReqLLM.Providers.register/1`,
  without editing core's list. Built-ins are always present; runtime
  registrations are merged over them (so a registration can override a built-in
  by key) and stored in `:persistent_term` (read-heavy, write-rare).

  No provider packaging is built yet; this is just the registration seam.
  """

  @pt_key {__MODULE__, :registered}

  @builtins %{
    google_calendar: Magus.Integrations.Providers.GoogleCalendar,
    log_source: Magus.Integrations.Providers.LogSource,
    simple_webhook: Magus.Integrations.Providers.SimpleWebhook,
    telegram: Magus.Integrations.Providers.Telegram,
    rss_source: Magus.Integrations.Providers.RssSource,
    notion_knowledge: Magus.Integrations.Providers.Notion,
    google_drive_knowledge: Magus.Integrations.Providers.GoogleDriveKnowledge,
    nextcloud_knowledge: Magus.Integrations.Providers.Nextcloud,
    affine_knowledge: Magus.Integrations.Providers.Affine,
    custom_api: Magus.Integrations.Providers.CustomApi.Provider,
    api: Magus.Integrations.Providers.Api
  }

  @doc "The built-in provider modules shipped with core."
  @spec builtins() :: %{atom() => module()}
  def builtins, do: @builtins

  @doc """
  Register a provider module at runtime under `key`. Overrides a built-in with
  the same key. Returns `:ok`.
  """
  @spec register(atom(), module()) :: :ok
  def register(key, module) when is_atom(key) and is_atom(module) do
    registered = :persistent_term.get(@pt_key, %{})
    :persistent_term.put(@pt_key, Map.put(registered, key, module))
    :ok
  end

  @doc """
  Register every provider from the `:magus, :extra_integration_providers` config
  (a keyword list or map of `key: module`). Called once at application boot so
  cloud/external providers are present before the first lookup, mirroring the
  other config-driven open-core seams. Returns the list of keys seeded.

      config :magus, :extra_integration_providers, my_provider: MyApp.Integrations.MyProvider
  """
  @spec seed_from_config() :: [atom()]
  def seed_from_config do
    :magus
    |> Application.get_env(:extra_integration_providers, [])
    |> Enum.map(fn {key, module} ->
      register(key, module)
      key
    end)
  end

  @doc "All provider modules: built-ins merged with runtime registrations."
  @spec all() :: %{atom() => module()}
  def all, do: Map.merge(@builtins, :persistent_term.get(@pt_key, %{}))

  @doc "The provider module registered under `key`, or `nil`."
  @spec get(atom()) :: module() | nil
  def get(key) when is_atom(key), do: Map.get(all(), key)
end
