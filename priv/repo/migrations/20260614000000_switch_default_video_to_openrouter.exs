defmodule Magus.Repo.Migrations.SwitchDefaultVideoToOpenrouter do
  @moduledoc """
  Data migration: move video generation to OpenRouter.

  The new OpenRouter video model rows are created by `priv/repo/seeds.exs`
  (via `Magus.Models.Catalog`). The seeds upsert intentionally preserves
  `active?`, `default_video?`, and `cost_multiplier` on existing rows, so it
  will neither deactivate the old Fal/AIML rows nor move the default. This
  migration does that part: deactivate Fal/AIML video rows and ensure the
  default points at Veo 3.1 Fast on OpenRouter. Both orderings (migrate-then-seed
  or seed-then-migrate) converge to exactly one active default.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE models
    SET "active?" = false, "default_video?" = false
    WHERE key LIKE 'fal:%' OR key LIKE 'aimlapi:%'
    """)

    execute("""
    UPDATE models
    SET "default_video?" = true
    WHERE key = 'openrouter:google/veo-3.1-fast'
    """)
  end

  def down do
    # Reverse the default flip. Old Fal/AIML rows are left deactivated
    # (re-activating them is an operator decision, not an automatic rollback).
    execute("""
    UPDATE models
    SET "default_video?" = false
    WHERE key = 'openrouter:google/veo-3.1-fast'
    """)

    execute("""
    UPDATE models
    SET "default_video?" = true
    WHERE key = 'fal:fal-ai/veo3.1'
    """)
  end
end
