defmodule Magus.Brain.ListSourcesTest do
  @moduledoc """
  Phase C5 sanity check on `Magus.Brain.list_sources/2`, the code
  interface backing the Sources panel. Confirms the brain-scope filter
  and the `actor:`-driven policy gate (the workbench uses an actor; the
  backfill workers use `authorize?: false`).
  """

  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Brain

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    %{user: user, brain: brain}
  end

  describe "list_sources/2" do
    test "returns sources scoped to the brain, newest first", %{user: user, brain: brain} do
      {:ok, _b} = Brain.create_brain(%{title: "Other"}, actor: user)

      # Seed two sources on this brain via `authorize?: false` because
      # the `forbid_if always()` policy prevents user-facing writes.
      attrs = fn url, title ->
        %{
          brain_id: brain.id,
          url: url,
          title: title,
          source_type: :web
        }
      end

      {:ok, _s1} =
        Ash.create(Magus.Brain.Source, attrs.("https://a.example", "First"), authorize?: false)

      :timer.sleep(5)

      {:ok, _s2} =
        Ash.create(Magus.Brain.Source, attrs.("https://b.example", "Second"), authorize?: false)

      assert {:ok, sources} = Brain.list_sources(brain.id, actor: user)
      titles = Enum.map(sources, & &1.title)
      assert "First" in titles
      assert "Second" in titles
      # `for_brain` sorts by `inserted_at: :desc`.
      [head | _] = sources
      assert head.title == "Second"
    end

    test "returns [] for brains the actor cannot see", %{user: user} do
      stranger = generate(user())
      {:ok, brain} = Brain.create_brain(%{title: "Theirs"}, actor: user)

      {:ok, _s} =
        Ash.create(
          Magus.Brain.Source,
          %{brain_id: brain.id, url: "https://x.example", title: "X", source_type: :web},
          authorize?: false
        )

      assert {:ok, []} = Brain.list_sources(brain.id, actor: stranger)
    end
  end
end
