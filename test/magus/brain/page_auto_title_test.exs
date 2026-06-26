defmodule Magus.Brain.PageAutoTitleTest do
  use Magus.ResourceCase, async: true

  alias Magus.Brain

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Test Brain"}, actor: user)
    %{user: user, brain: brain}
  end

  describe "needs_title calculation (body-based)" do
    test "true for Untitled page with substantial body and age", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{}, actor: user)
      body = "# Some Heading\n\n" <> String.duplicate("Some longer text. ", 20)

      {:ok, page} =
        Brain.update_page_body(page, %{body: body, base_version: page.lock_version}, actor: user)

      backdate_inserted_at(page.id, "10 minutes")

      {:ok, loaded} = Ash.load(page, [:needs_title], authorize?: false)
      assert loaded.needs_title == true
    end

    test "false for page with a custom title", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Custom"}, actor: user)
      body = String.duplicate("Filler. ", 50)

      {:ok, page} =
        Brain.update_page_body(page, %{body: body, base_version: page.lock_version}, actor: user)

      backdate_inserted_at(page.id, "10 minutes")

      {:ok, loaded} = Ash.load(page, [:needs_title], authorize?: false)
      assert loaded.needs_title == false
    end

    test "false for Untitled page with body shorter than 100 chars",
         %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{}, actor: user)

      {:ok, page} =
        Brain.update_page_body(page, %{body: "short", base_version: page.lock_version},
          actor: user
        )

      backdate_inserted_at(page.id, "10 minutes")

      {:ok, loaded} = Ash.load(page, [:needs_title], authorize?: false)
      assert loaded.needs_title == false
    end

    test "false for Untitled page with nil body", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{}, actor: user)
      backdate_inserted_at(page.id, "10 minutes")

      {:ok, loaded} = Ash.load(page, [:needs_title], authorize?: false)
      assert loaded.needs_title == false
    end

    test "false for brand new Untitled page (less than 5 min old)",
         %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{}, actor: user)
      body = "# A Heading\n\n" <> String.duplicate("Sentence body. ", 20)

      {:ok, page} =
        Brain.update_page_body(page, %{body: body, base_version: page.lock_version}, actor: user)

      # do NOT backdate

      {:ok, loaded} = Ash.load(page, [:needs_title], authorize?: false)
      assert loaded.needs_title == false
    end
  end

  describe "generate_name end-to-end (body H1 extraction)" do
    test "sets the title from the first H1 of the body", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{}, actor: user)

      {:ok, page} =
        Brain.update_page_body(
          page,
          %{body: "# Elixir Tips\n\nPattern matching rocks.\n", base_version: page.lock_version},
          actor: user
        )

      {:ok, updated} =
        Ash.Changeset.for_update(page, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert updated.title == "Elixir Tips"
    end
  end

  defp backdate_inserted_at(page_id, interval) do
    {:ok, uuid_binary} = Ecto.UUID.dump(page_id)

    Magus.Repo.query!(
      "UPDATE brain_pages SET inserted_at = NOW() - INTERVAL '#{interval}' WHERE id = $1",
      [uuid_binary]
    )
  end
end
