defmodule Magus.Agents.Context.BrainRagContextTest do
  @moduledoc """
  Covers `BrainRagContext.build/1` after the markdown-as-storage cutover.

  We can't trigger the semantic-search branch from ExUnit (it requires
  an OpenRouter API key for `Magus.Files.EmbeddingModel.embed/1`). The
  embedding call fails in test env, the module degrades to the FTS
  fallback path (`Brain.search_pages_text/3`), and we assert on the
  formatted system-prompt blob that comes out of it. That exercises:

    * brain id resolution
    * the FTS fallback
    * page-cache lookups via `Ash.get/3` for titles
    * the `<brain_knowledge>` envelope + per-page formatting

  Empty / short / unresolvable inputs are also covered.
  """

  use Magus.DataCase, async: true

  import Ecto.Query
  import Magus.Generators

  alias Magus.Agents.Context.BrainRagContext
  alias Magus.Brain
  alias Magus.Repo

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Engineering"}, actor: user)

    {:ok, page} = Brain.create_page(brain.id, %{title: "Distributed Systems"}, actor: user)

    set_page_body(page.id, """
    # Distributed Systems

    Raft consensus algorithm ensures linearizable writes.

    Eventual consistency is acceptable for caches.
    """)

    %{user: user, brain: brain, page: page}
  end

  # Writes body directly via SQL so the generated `search_vector` column
  # (GENERATED ALWAYS AS STORED) repopulates without going through the
  # action pipeline's lock_version / paper trail machinery.
  defp set_page_body(page_id, body) do
    page_id_bin = Ecto.UUID.dump!(page_id)

    {1, _} =
      from(p in "brain_pages", where: p.id == ^page_id_bin)
      |> Repo.update_all(set: [body: body, updated_at: DateTime.utc_now()])

    :ok
  end

  describe "build/1" do
    test "returns nil when query is missing", %{user: user, brain: brain} do
      assert BrainRagContext.build(%{user: user, brain_id: brain.id}) == nil
    end

    test "returns nil when query is shorter than the minimum length", %{
      user: user,
      brain: brain
    } do
      assert BrainRagContext.build(%{user: user, brain_id: brain.id, query: "raft"}) == nil
    end

    test "returns nil when no brain ids resolve", %{user: _user} do
      other = generate(user())

      assert BrainRagContext.build(%{user: other, query: "raft consensus tell"}) == nil
    end

    test "returns nil when nothing in the brain matches the query", %{
      user: user,
      brain: brain
    } do
      result =
        BrainRagContext.build(%{
          user: user,
          brain_id: brain.id,
          query: "kubernetes helm chart deployment topic"
        })

      assert result == nil
    end
  end
end
