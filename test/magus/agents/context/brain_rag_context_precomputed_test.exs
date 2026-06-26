defmodule Magus.Agents.Context.BrainRagContextPrecomputedTest do
  @moduledoc """
  Verifies that `BrainRagContext.build/1` uses a precomputed `:query_embedding`
  when one is supplied, instead of embedding the query itself.

  The agent context builder embeds the query ONCE per message and shares the
  vector across every retriever (memory, file RAG, brain RAG). This test runs
  with the embedding provider key cleared, so the internal `embed/1` path is
  unavailable: the only way to reach the semantic chunk search is via the
  supplied vector. A control test (no vector) confirms `embed/1` truly cannot
  run here, so the semantic hit can only come from the precomputed embedding.

  `async: false` because it mutates process/application env (the API key).
  """

  use Magus.DataCase, async: false

  import Ecto.Query
  import Magus.Generators

  alias Magus.Agents.Context.BrainRagContext
  alias Magus.Brain
  alias Magus.Brain.PageChunk
  alias Magus.Repo

  setup do
    prev_sys = System.get_env("OPENROUTER_API_KEY")
    prev_app = Application.get_env(:magus, :openrouter_api_key)
    System.delete_env("OPENROUTER_API_KEY")
    Application.put_env(:magus, :openrouter_api_key, nil)

    on_exit(fn ->
      if prev_sys,
        do: System.put_env("OPENROUTER_API_KEY", prev_sys),
        else: System.delete_env("OPENROUTER_API_KEY")

      Application.put_env(:magus, :openrouter_api_key, prev_app)
    end)

    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Engineering"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "Notes"}, actor: user)

    # Body shares no terms with the query below, so the FTS fallback finds
    # nothing — isolating the semantic path as the only source of a hit.
    set_page_body(page.id, "Networking notes about routers and switches.")

    {:ok, _chunk} =
      PageChunk
      |> Ash.Changeset.for_create(:create, %{
        page_id: page.id,
        index: 0,
        content: "Photosynthesis converts sunlight into chemical energy in plants.",
        token_count: 12,
        embedding: List.duplicate(0.05, 1536)
      })
      |> Ash.create(authorize?: false)

    %{user: user, brain: brain}
  end

  defp set_page_body(page_id, body) do
    page_id_bin = Ecto.UUID.dump!(page_id)

    {1, _} =
      from(p in "brain_pages", where: p.id == ^page_id_bin)
      |> Repo.update_all(set: [body: body, updated_at: DateTime.utc_now()])

    :ok
  end

  @query "Photosynthesis chlorophyll biology process explained"

  test "control: without a vector the embed path is unavailable and FTS finds nothing", %{
    user: user,
    brain: brain
  } do
    assert BrainRagContext.build(%{user: user, brain_id: brain.id, query: @query}) == nil
  end

  test "uses the supplied vector to run the semantic chunk search", %{user: user, brain: brain} do
    result =
      BrainRagContext.build(%{
        user: user,
        brain_id: brain.id,
        query: @query,
        query_embedding: List.duplicate(0.05, 1536)
      })

    assert result =~ "Photosynthesis converts sunlight"
  end
end
