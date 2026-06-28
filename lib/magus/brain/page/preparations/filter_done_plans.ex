defmodule Magus.Brain.Page.Preparations.FilterDonePlans do
  @moduledoc """
  Keeps only pages whose computed `:lifecycle` is `:done` (the stranded-plan
  set). `lifecycle` is an Elixir-evaluated calc that recurses over child phases
  and joins tasks, so it cannot be pushed into the SQL `WHERE`. The
  `:stranded_plans` read narrows to candidate `:plan` pages in SQL; this
  preparation loads the calc and filters the result set in memory.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, context) do
    opts = Ash.Context.to_opts(context)

    Ash.Query.after_action(query, fn _query, results ->
      # Load the calc on the result set here (not via Query.load) so the value
      # is materialised before we filter: query-level loads can be applied after
      # after_action hooks run, leaving `lifecycle` as %Ash.NotLoaded{}.
      loaded = Ash.load!(results, :lifecycle, opts)
      {:ok, Enum.filter(loaded, &(&1.lifecycle == :done))}
    end)
  end
end
