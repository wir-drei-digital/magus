defmodule Magus.Models.Catalog do
  @moduledoc """
  Curated model catalog seam. Empty in the open-core (`magus`) build.

  OSS starts with no curated models: a fresh self-host install has an empty
  catalog, and the operator adds a provider and imports models via the admin.
  The commercial catalog data lives in `MagusCloud.Models.Catalog` and is
  seeded by `magus_cloud` (see `magus-mxj5.6`). At runtime the LLMDB `:custom`
  registry is built from DB rows by `Magus.Models.CatalogSync`, never from this
  module, so an empty catalog here has no runtime effect.

  The module and its transformers (`to_db_attrs/1`, `to_llm_metadata/1`,
  `llmdb_provider_meta/1`) remain so the data-migration helpers
  (`Magus.Models.Backfill` / `Magus.Models.InternalizeExtras`) keep compiling
  and simply no-op over the empty `@models` list.
  """

  @type model :: map()

  @models []

  @doc "All catalog entries (filtered to those that should be seeded)."
  @spec all() :: [model()]
  def all, do: Enum.filter(@models, &Map.get(&1, :seed?, true))

  @doc "All catalog entries, including LLMDB-only utility models."
  @spec all_with_internal() :: [model()]
  def all_with_internal, do: @models

  # Allowlist mirroring `Magus.Chat.Model`'s `:create` action. Anything not
  # in this list is dropped by `to_db_attrs/1`, including the `llmdb_*`
  # internal fields and any forward-compatible keys we add to entries.
  @db_attrs ~w(
    name key provider api_provider denied_providers context_window
    input_cost output_cost input_cost_value output_cost_value
    input_cost_unit output_cost_unit
    active? settings
    input_modalities output_modalities
    supports_search? supports_reasoning? supports_tools?
    short_description detailed_description
    short_description_translations detailed_description_translations
    info released_at options
  )a

  @doc """
  Returns Magus.Chat.Model attrs for a single catalog entry, keeping
  only fields the resource's `:create` action accepts. Catalog-internal
  fields (`seed?`, `llmdb_*`) and any future keys are dropped here so
  unknown attributes never reach the changeset. The `llmdb_*` override
  fields are folded into the `:llm_metadata` attr via `to_llm_metadata/1`.
  """
  @spec to_db_attrs(model()) :: map()
  def to_db_attrs(model) do
    model
    |> Map.take(@db_attrs)
    |> Map.put(:llm_metadata, to_llm_metadata(model))
  end

  @llm_metadata_mapping [
    llmdb_output_limit: "output_limit",
    llmdb_context: "context",
    llmdb_input_cost: "input_cost",
    llmdb_output_cost: "output_cost",
    llmdb_cache_read: "cache_read",
    llmdb_cache_write: "cache_write",
    llmdb_skip_tools?: "skip_tools",
    llmdb_skip_reasoning?: "skip_reasoning",
    llmdb_simple_streaming?: "simple_streaming",
    llmdb_simple_capabilities?: "simple_capabilities",
    llmdb_input_modalities: "input_modalities",
    llmdb_output_modalities: "output_modalities"
  ]

  @doc """
  Extracts the `llmdb_*` override fields of a catalog entry into the
  string-keyed `llm_metadata` map stored on `Magus.Chat.Model`.
  """
  @spec to_llm_metadata(model()) :: map()
  def to_llm_metadata(entry) do
    for {source, target} <- @llm_metadata_mapping,
        (value = Map.get(entry, source)) != nil,
        into: %{} do
      {target, value}
    end
  end

  # LLMDB provider registry. Each entry must be referenceable by
  # `llmdb_provider:` on a catalog model. To add a new provider, add a
  # row here. `req_llm_id` selects the ReqLLM provider module; it equals
  # the slug for every current entry. This map is the single source of
  # truth for provider metadata (see `InternalizeExtras`).
  @llmdb_providers %{
    openrouter: %{
      name: "OpenRouter",
      req_llm_id: "openrouter",
      base_url: "https://openrouter.ai/api/v1"
    },
    openrouter_citations: %{
      name: "OpenRouter (Citations)",
      req_llm_id: "openrouter_citations",
      base_url: "https://openrouter.ai/api/v1"
    },
    publicai: %{
      name: "PublicAI",
      req_llm_id: "publicai",
      base_url: "https://api.publicai.co/v1"
    }
  }

  @doc """
  Provider metadata (`%{name, req_llm_id, base_url}`) for an LLMDB provider,
  keyed by its slug (the DB Provider `slug`, which equals the catalog key
  prefix). Accepts the slug as a string or an atom. Raises if unknown.
  """
  @spec llmdb_provider_meta(String.t() | atom()) :: %{
          name: String.t(),
          req_llm_id: String.t(),
          base_url: String.t()
        }
  def llmdb_provider_meta(slug) when is_binary(slug),
    do: llmdb_provider_meta(String.to_existing_atom(slug))

  def llmdb_provider_meta(slug) when is_atom(slug),
    do: Map.fetch!(@llmdb_providers, slug)
end
