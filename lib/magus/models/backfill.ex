defmodule Magus.Models.Backfill do
  @moduledoc """
  One-time backfill: creates Provider rows from the legacy `api_provider`
  enum on models, links models via `model_provider_id`, and copies the
  catalog's `llmdb_*` overrides into `llm_metadata` (matched by key).

  Idempotent: safe to run repeatedly. Invoked from the data migration and
  reusable from seeds. Never mutates model ids or keys — UPDATE only.

  > One-shot data-migration helper invoked from a migration (and seeds), not
  > general runtime code. Do not call from request/agent paths.
  """

  import Ecto.Query
  alias Magus.Repo

  # api_provider enum value => {display name, req_llm provider id}
  @provider_map %{
    "openrouter" => {"OpenRouter", "openrouter"},
    "xai" => {"xAI", "xai"},
    "publicai" => {"PublicAI", "publicai"},
    "aimlapi" => {"AIMLAPI", "aimlapi"},
    "fal" => {"fal.ai", "fal"}
  }

  @spec run() :: :ok
  def run do
    ensure_providers()
    link_models()
    backfill_llm_metadata()
    :ok
  end

  defp ensure_providers do
    used =
      Repo.all(from m in "models", distinct: true, select: m.api_provider)
      |> Enum.reject(&is_nil/1)

    now = DateTime.utc_now()

    for api_provider <- used do
      {name, req_llm_id} =
        Map.get(@provider_map, api_provider, {api_provider, api_provider})

      Repo.insert_all(
        "model_providers",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            name: name,
            slug: api_provider,
            req_llm_id: req_llm_id,
            enabled?: true,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:slug]
      )
    end

    :ok
  end

  defp link_models do
    Repo.query!(
      """
      UPDATE models m
      SET model_provider_id = p.id
      FROM model_providers p
      WHERE p.slug = m.api_provider AND m.model_provider_id IS NULL
      """,
      []
    )

    :ok
  end

  defp backfill_llm_metadata do
    for entry <- Magus.Models.Catalog.all_with_internal() do
      metadata = Magus.Models.Catalog.to_llm_metadata(entry)

      if metadata != %{} do
        from(m in "models",
          where: m.key == ^entry.key and m.llm_metadata == ^%{}
        )
        |> Repo.update_all(set: [llm_metadata: metadata])
      end
    end

    :ok
  end
end
