defmodule Magus.Brain.PageTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Brain

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Test Brain"}, actor: user)
    %{user: user, brain: brain}
  end

  describe "create_page/2" do
    test "creates a page in a brain", %{user: user, brain: brain} do
      assert {:ok, page} = Brain.create_page(brain.id, %{title: "Scaling Laws"}, actor: user)
      assert page.title == "Scaling Laws"
      assert page.brain_id == brain.id
      assert page.slug != nil
      assert page.position != nil
      assert page.contributor_type == :user
      assert page.contributor_id == user.id
    end

    test "auto-assigns incrementing position", %{user: user, brain: brain} do
      {:ok, page1} = Brain.create_page(brain.id, %{title: "Page 1"}, actor: user)
      {:ok, page2} = Brain.create_page(brain.id, %{title: "Page 2"}, actor: user)
      assert page2.position > page1.position
    end

    test "generates slug from title", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Hello World"}, actor: user)
      assert page.slug =~ ~r/^hello-world-[a-z0-9_-]+$/
    end

    test "allows creating a page without a title (auto-named later)", %{user: user, brain: brain} do
      assert {:ok, page} = Brain.create_page(brain.id, %{}, actor: user)
      assert is_nil(page.title)
      assert page.slug =~ ~r/^untitled-[a-z0-9_-]+$/
    end

    test "does not allow creating pages in another user's brain", %{brain: brain} do
      other_user = generate(user())

      assert {:error, %Ash.Error.Forbidden{}} =
               Brain.create_page(brain.id, %{title: "Unauthorized"}, actor: other_user)
    end
  end

  describe "list_pages/2" do
    test "lists pages for a brain ordered by position", %{user: user, brain: brain} do
      {:ok, _} = Brain.create_page(brain.id, %{title: "Page B"}, actor: user)
      {:ok, _} = Brain.create_page(brain.id, %{title: "Page A"}, actor: user)
      assert {:ok, pages} = Brain.list_pages(brain.id, actor: user)
      assert length(pages) == 2
      assert Enum.at(pages, 0).title == "Page B"
    end

    test "does not list pages from another user's brain", %{user: user, brain: _brain} do
      other_user = generate(user())
      {:ok, other_brain} = Brain.create_brain(%{title: "Other Brain"}, actor: other_user)
      {:ok, _} = Brain.create_page(other_brain.id, %{title: "Secret"}, actor: other_user)

      assert {:ok, pages} = Brain.list_pages(other_brain.id, actor: user)
      assert pages == []
    end
  end

  describe "get_page/2" do
    test "returns a page by id", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Test Page"}, actor: user)
      assert {:ok, found} = Brain.get_page(page.id, actor: user)
      assert found.id == page.id
    end

    test "does not return pages from another user's brain", %{user: user, brain: _brain} do
      other_user = generate(user())
      {:ok, other_brain} = Brain.create_brain(%{title: "Other Brain"}, actor: other_user)
      {:ok, page} = Brain.create_page(other_brain.id, %{title: "Secret"}, actor: other_user)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Brain.get_page(page.id, actor: user)
    end
  end

  describe "update_page_title/3" do
    test "updates page title", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Old Title"}, actor: user)
      assert {:ok, updated} = Brain.update_page_title(page, %{title: "New Title"}, actor: user)
      assert updated.title == "New Title"
    end
  end

  describe "find_page_by_title/3" do
    test "finds a page by title within a brain", %{user: user, brain: brain} do
      {:ok, _} = Brain.create_page(brain.id, %{title: "Target Page"}, actor: user)
      assert {:ok, [found]} = Brain.find_page_by_title(brain.id, "Target Page", actor: user)
      assert found.title == "Target Page"
    end

    test "returns empty list when not found", %{user: user, brain: brain} do
      assert {:ok, []} = Brain.find_page_by_title(brain.id, "Nonexistent", actor: user)
    end
  end

  describe "destroy_page/2" do
    test "destroys a page", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "To Delete"}, actor: user)
      assert :ok = Brain.destroy_page(page, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Brain.get_page(page.id, actor: user)
    end
  end

  describe "companion link cleanup" do
    test "destroying a brain page unlinks any companion conversations", %{
      user: user,
      brain: brain
    } do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Companion Page"}, actor: user)

      {:ok, conv} =
        Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

      assert :ok = Brain.destroy_page(page, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Magus.Chat.get_companion_by_conversation(conv.id, actor: user)

      # Conversation itself remains
      assert {:ok, _} = Magus.Chat.get_conversation(conv.id, actor: user)
    end
  end
end
