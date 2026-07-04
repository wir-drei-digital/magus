defmodule Magus.Repo.Migrations.SeedAllowedOpenRouterProviders do
  @moduledoc """
  Seeds the US/EU/CH OpenRouter provider slugs as `allowed: true` so cloud
  behavior matches the previous data-region defaults before any admin sync.

  Snapshot of the (about-to-be-removed) `config :magus, :data_regions`
  `providers:` map, US + EU + CH buckets only. The CN/SG slugs (deepseek,
  alibaba, siliconflow, minimax, moonshot-ai, z-ai) are intentionally omitted
  so they start `allowed: false` (fail closed). `name` is seeded to the slug
  as a placeholder; the first real sync overwrites it (upsert refreshes name).
  """
  use Ecto.Migration

  import Ecto.Query

  @slugs ~w(
    anthropic openai google-ai-studio google-vertex amazon-bedrock amazon-nova
    azure together deepinfra fireworks groq cerebras sambanova novita parasail
    chutes baseten venice perplexity nvidia inflection cohere crusoe hyperbolic
    ai21 inceptron nextbit ionstream phala gmicloud atlascloud ambient io-net
    xai mistral nebius cloudflare publicai
  )

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(@slugs, fn slug ->
        %{
          id: Ecto.UUID.bingenerate(),
          slug: slug,
          name: slug,
          datacenters: [],
          allowed: true,
          inserted_at: now,
          updated_at: now
        }
      end)

    # ON CONFLICT (slug) DO NOTHING: never clobber an admin decision if a row
    # already exists (e.g. a manual sync ran before this migration).
    repo().insert_all("open_router_providers", entries,
      on_conflict: :nothing,
      conflict_target: :slug
    )
  end

  def down do
    repo().delete_all(from(p in "open_router_providers", where: p.slug in ^@slugs))
  end
end
