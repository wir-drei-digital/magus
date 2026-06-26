defmodule Magus.Brain.ResolverTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Brain.Resolver

  setup do
    user = generate(user())
    {:ok, brain} = Magus.Brain.create_brain(%{title: "Workshop"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Notes"}, actor: user)
    %{user: user, brain: brain, page: page}
  end

  describe "resolve_brain_id/2" do
    test "returns the given id without lookup when explicit", %{user: user} do
      assert {:ok, "explicit"} = Resolver.resolve_brain_id(user, "explicit")
    end

    test "auto-discovers the user's first brain when no id is given", %{user: user, brain: brain} do
      assert {:ok, id} = Resolver.resolve_brain_id(user, nil)
      assert id == brain.id
    end

    test "returns an error when the user has no brains" do
      user = generate(user())
      assert {:error, _} = Resolver.resolve_brain_id(user, nil)
    end
  end

  describe "resolve_page/3" do
    test "fetches a page by id", %{user: user, brain: brain, page: page} do
      assert {:ok, %{id: id}} = Resolver.resolve_page(user, brain.id, page_id: page.id)
      assert id == page.id
    end

    test "fetches a page by title within a brain", %{user: user, brain: brain, page: page} do
      assert {:ok, %{id: id}} = Resolver.resolve_page(user, brain.id, page_title: page.title)
      assert id == page.id
    end

    test "returns an error when title does not match", %{user: user, brain: brain} do
      assert {:error, _} = Resolver.resolve_page(user, brain.id, page_title: "Nope")
    end

    test "returns an error when no identifier is given", %{user: user, brain: brain} do
      assert {:error, _} = Resolver.resolve_page(user, brain.id, [])
    end
  end

  describe "list_brain_summaries/1" do
    test "returns {id, title} tuples for the actor's brains", %{user: user, brain: brain} do
      assert {:ok, [{id, title}]} = Resolver.list_brain_summaries(user)
      assert id == brain.id
      assert title == brain.title
    end
  end
end
