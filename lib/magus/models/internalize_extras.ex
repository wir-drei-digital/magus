defmodule Magus.Models.InternalizeExtras do
  @moduledoc """
  One-time move of the catalog's LLMDB-only static extras into DB rows:
  the `:openrouter_citations` provider and every `seed?: false` catalog
  entry (plus the citations Sonar model) become provider-linked,
  `internal?: true` models, so CatalogSync's DB build covers them and the
  static merge can be deleted.

  Idempotent: creates missing rows and reconciles a pre-existing seeded row
  (e.g. the citations Sonar model) into the internal, provider-linked, active
  state. Bootstraps the providers it needs by key prefix, so it works against
  a fresh (empty) database as well as an already-seeded one.

  > One-shot data-migration helper invoked from a migration (and seeds), not
  > general runtime code. Do not call from request/agent paths.
  """

  require Ash.Query

  @spec run() :: :ok
  def run do
    entries = internal_entries()

    entries
    |> Enum.map(&key_prefix(&1.key))
    |> Enum.uniq()
    |> Enum.each(&ensure_provider/1)

    Enum.each(entries, &ensure_internal_model/1)

    :ok
  end

  # The catalog entries that were only ever registered in LLMDB (never
  # seeded as user-facing rows): the explicit `seed?: false` utility models
  # plus the citations Sonar model (whose provider has no DB row today).
  defp internal_entries do
    Magus.Models.Catalog.all_with_internal()
    |> Enum.filter(fn entry ->
      Map.get(entry, :seed?, true) == false or
        Map.get(entry, :llmdb_provider) == :openrouter_citations
    end)
  end

  defp key_prefix(key), do: key |> String.split(":", parts: 2) |> List.first()

  # Some utility entries carry no display name (LLMDB-only); fall back to the
  # model id portion of the key, which `name`'s non-null constraint requires.
  defp fallback_name(entry) do
    Map.get(entry, :llmdb_model_id) || entry.key |> String.split(":", parts: 2) |> List.last()
  end

  defp ensure_provider(slug) do
    case Magus.Models.get_provider_by_slug(slug) do
      {:ok, %Magus.Models.Provider{}} ->
        :ok

      _ ->
        %{name: name, req_llm_id: req_llm_id, base_url: base_url} =
          Magus.Models.Catalog.llmdb_provider_meta(slug)

        Magus.Models.create_provider!(
          %{name: name, slug: slug, req_llm_id: req_llm_id, base_url: base_url},
          authorize?: false
        )
    end
  end

  defp ensure_internal_model(entry) do
    slug = key_prefix(entry.key)
    {:ok, provider} = Magus.Models.get_provider_by_slug(slug)

    existing =
      Magus.Chat.Model
      |> Ash.Query.filter(key == ^entry.key)
      |> Ash.read_one!(authorize?: false)

    case existing do
      nil ->
        create_internal_model(entry, provider)

      model ->
        reconcile_internal_model(model, provider)
    end
  end

  defp create_internal_model(entry, provider) do
    attrs =
      entry
      |> Magus.Models.Catalog.to_db_attrs()
      |> Map.put_new(:name, fallback_name(entry))
      |> Map.put(:internal?, true)
      |> Map.put(:active?, true)
      |> Map.put(:model_provider_id, provider.id)

    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  # On an existing install the catalog model may already exist (it was seeded
  # before this provider model was introduced). Reconcile it to the internal,
  # provider-linked, active state CatalogSync/LLMDB require — e.g. the seeded
  # citations Sonar row, linked to the wrong provider and not flagged internal.
  defp reconcile_internal_model(model, provider) do
    if model.internal? and model.active? and model.model_provider_id == provider.id do
      :ok
    else
      model
      |> Ash.Changeset.for_update(:update, %{
        internal?: true,
        active?: true,
        model_provider_id: provider.id
      })
      |> Ash.update!(authorize?: false)
    end
  end
end
