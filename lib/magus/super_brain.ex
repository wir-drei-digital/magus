defmodule Magus.SuperBrain do
  @moduledoc """
  Domain for the Super Brain cross-resource knowledge graph.

  The Super Brain extracts structured knowledge from across the user's
  resources (brain pages, memories, files, drafts, messages) into a
  FalkorDB graph keyed by `graph_name`.

  This domain owns the Postgres-side bookkeeping for that pipeline:
  Episodes (one row per source content the system has tried to extract
  from), extraction budgets, and graph weights.
  """

  use Ash.Domain, otp_app: :magus

  @doc """
  Master kill switch for the Super Brain feature.

  When `false`, ALL Super Brain work is disabled: extraction/build/scheduler
  Oban jobs `{:cancel, :super_brain_disabled}` instead of running, enqueue
  sites skip insertion, the per-message `<super_brain>` retrieval context is
  not injected, and the `super_brain_search` / `pin_fact` agent tools are not
  offered. Defaults to `false`; set `config :magus, :super_brain_enabled,
  true` (or `SUPER_BRAIN_ENABLED=true` in prod) to turn it on.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:magus, :super_brain_enabled, false)

  resources do
    resource Magus.SuperBrain.Episode do
      define :create_episode, action: :create
      define :get_episode, action: :read, get_by: [:id]
      define :list_pending_episodes, action: :list_pending
    end

    resource Magus.SuperBrain.ExtractionBudget

    resource Magus.SuperBrain.GraphWeight

    resource Magus.SuperBrain.SuperGraph do
      define :get_super_graph, action: :read, get_by: [:id]
      define :create_super_graph, action: :create
    end
  end
end
