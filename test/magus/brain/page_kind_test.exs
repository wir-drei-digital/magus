defmodule Magus.Brain.PageKindTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Brain

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Test Brain"}, actor: user)
    %{user: user, brain: brain}
  end

  describe "page :kind" do
    test "defaults to :page on create", %{user: user, brain: brain} do
      assert {:ok, page} = Brain.create_page(brain.id, %{title: "Plain Page"}, actor: user)
      assert page.kind == :page
    end

    test "promotes a page to :plan", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Roadmap"}, actor: user)

      assert {:ok, promoted} = Brain.set_page_kind(page, :plan, actor: user)
      assert promoted.kind == :plan
    end

    test "demotes a plan back to :page", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Roadmap"}, actor: user)
      {:ok, promoted} = Brain.set_page_kind(page, :plan, actor: user)

      assert {:ok, demoted} = Brain.set_page_kind(promoted, :page, actor: user)
      assert demoted.kind == :page
    end

    test "rejects an unknown kind", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Roadmap"}, actor: user)

      assert {:error, %Ash.Error.Invalid{}} = Brain.set_page_kind(page, :spec, actor: user)
    end
  end
end
