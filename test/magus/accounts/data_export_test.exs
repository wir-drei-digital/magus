defmodule Magus.Accounts.DataExportTest do
  use Magus.ResourceCase, async: true

  import Ecto.Query

  alias Magus.Accounts.DataExport

  describe "build/1" do
    test "returns map with schema_version 1 and the expected top-level keys" do
      user = generate(user())
      data = DataExport.build(user)

      assert data.schema_version == 1
      assert %DateTime{} = data.exported_at

      for key <- [
            :profile,
            :conversations,
            :folders,
            :memories,
            :brains,
            :custom_agents,
            :prompts,
            :favorites,
            :drafts
          ] do
        assert Map.has_key?(data, key), "missing top-level key: #{inspect(key)}"
      end
    end

    test "profile contains the expected fields and excludes sensitive ones" do
      user = generate(user(display_name: "Alice"))
      data = DataExport.build(user)

      assert data.profile.email == to_string(user.email)
      assert data.profile.display_name == "Alice"
      assert data.profile.language == :en

      refute Map.has_key?(data.profile, :hashed_password)
      refute Map.has_key?(data.profile, :confirmation_token)
    end

    test "round-trips cleanly through Jason.encode!/1" do
      user = generate(user())
      data = DataExport.build(user)

      assert {:ok, json} = Jason.encode(data, pretty: true)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["schema_version"] == 1
    end

    test "isolation: includes nothing belonging to a different user" do
      user_a = generate(user())
      user_b = generate(user())

      {:ok, _conv_b} = Magus.Chat.create_conversation(%{title: "user_b conv"}, actor: user_b)

      data = DataExport.build(user_a)
      json = Jason.encode!(data)

      refute json =~ "user_b conv"
    end

    test "exports conversations the user OWNS, with messages inlined" do
      user = generate(user())
      {:ok, conv} = Magus.Chat.create_conversation(%{title: "MyChat"}, actor: user)

      {:ok, _msg} =
        Magus.Chat.create_message(%{conversation_id: conv.id, text: "hi"}, actor: user)

      data = DataExport.build(user)

      assert [exported] = data.conversations
      assert exported.id == conv.id
      assert exported.title == "MyChat"
      assert [%{text: "hi"}] = exported.messages
    end

    test "does NOT export multiplayer conversations the user only joined" do
      owner = generate(user())
      member = generate(user())

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Owner-owned multi"}, actor: owner)

      {:ok, _enabled} = Magus.Chat.enable_multiplayer(conv, actor: owner)

      _cm =
        Magus.Chat.ConversationMember
        |> Ash.Changeset.for_create(
          :add_member,
          %{conversation_id: conv.id, user_id: member.id, role: :member},
          authorize?: false
        )
        |> Ash.Changeset.force_change_attribute(:accepted_at, DateTime.utc_now())
        |> Ash.create!(authorize?: false)

      {:ok, _msg} =
        Magus.Chat.create_message(%{conversation_id: conv.id, text: "owner-only"}, actor: owner)

      data = DataExport.build(member)
      json = Jason.encode!(data)

      assert data.conversations == []
      refute json =~ "Owner-owned multi"
      refute json =~ "owner-only"
    end

    test "exports folders the user owns" do
      user = generate(user())
      {:ok, folder} = Magus.Chat.create_folder(%{name: "Work"}, actor: user)

      data = DataExport.build(user)

      assert [%{id: id, name: "Work"}] = data.folders
      assert id == folder.id
    end

    test "exports memories with versions and sources" do
      user = generate(user())
      {:ok, conv} = Magus.Chat.create_conversation(%{title: "C"}, actor: user)

      {:ok, mem} =
        Magus.Memory.create_memory(
          conv.id,
          user.id,
          "preferences",
          %{summary: "I like X", content: %{"a" => 1}},
          actor: user
        )

      data = DataExport.build(user)

      assert [exported] = data.memories
      assert exported.id == mem.id
      assert exported.name == "preferences"
      assert exported.summary == "I like X"
      assert exported.content == %{"a" => 1}
      assert is_list(exported.versions)
      assert is_list(exported.sources)
    end

    test "exports brains with pages including body, frontmatter, tags, and wikilinks" do
      user = generate(user())
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Research"}, actor: user)
      {:ok, _target} = Magus.Brain.create_page(brain.id, %{title: "Target Page"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Notes"}, actor: user)

      body = """
      ---
      icon: 🧠
      tags: [ml, research]
      ---
      # Notes

      Linking to [[Target Page]] and #inline-tag here.
      """

      {:ok, _updated} =
        Magus.Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)

      data = DataExport.build(user)

      assert [exported_brain] = data.brains
      assert exported_brain.title == "Research"
      assert exported_brain.is_archived == false

      pages_by_title = Map.new(exported_brain.pages, &{&1.title, &1})

      exported_page = Map.fetch!(pages_by_title, "Notes")
      assert exported_page.body == body
      assert exported_page.frontmatter["icon"] == "🧠"
      assert exported_page.frontmatter["tags"] == ["ml", "research"]

      refute Map.has_key?(exported_page, :blocks)

      tags_by_name = Map.new(exported_page.tags, &{&1.tag, &1.source})
      assert tags_by_name["ml"] == :frontmatter
      assert tags_by_name["research"] == :frontmatter
      assert tags_by_name["inline-tag"] == :inline

      assert "Target Page" in exported_page.wikilinks

      # Sibling page exists in the export too, with no derived content
      empty_target = Map.fetch!(pages_by_title, "Target Page")
      assert empty_target.body == nil
      assert empty_target.tags == []
      assert empty_target.wikilinks == []
      refute Map.has_key?(empty_target, :blocks)
    end

    test "strips frontmatter sentinel keys from the export" do
      user = generate(user())
      {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

      # Simulate parser sentinels landing in the persisted frontmatter cache.
      page_id_bin = Ecto.UUID.dump!(page.id)

      {1, _} =
        from(p in "brain_pages", where: p.id == ^page_id_bin)
        |> Magus.Repo.update_all(
          set: [
            frontmatter: %{
              "tags" => ["keep"],
              "_no_frontmatter" => true,
              "_parse_error" => "boom",
              "_links_built_at" => "2026-01-01T00:00:00Z",
              "_sources_built_at" => "2026-01-01T00:00:00Z",
              "_tags_built_at" => "2026-01-01T00:00:00Z"
            },
            updated_at: DateTime.utc_now()
          ]
        )

      data = DataExport.build(user)

      assert [exported_brain] = data.brains
      assert [exported_page] = exported_brain.pages
      assert exported_page.frontmatter == %{"tags" => ["keep"]}
    end

    test "exports an empty brain with no pages as pages: []" do
      user = generate(user())
      {:ok, _brain} = Magus.Brain.create_brain(%{title: "Empty"}, actor: user)

      data = DataExport.build(user)

      assert [exported_brain] = data.brains
      assert exported_brain.pages == []
    end

    test "exports custom_agents with secret_names listed but no secret values" do
      user = generate(user())

      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "Bot", instructions: "do things"},
          actor: user
        )

      {:ok, _secret} =
        Magus.Agents.AgentSecret
        |> Ash.Changeset.for_create(
          :create,
          %{
            custom_agent_id: agent.id,
            key: "openai_key",
            value: "SUPER_SECRET_VALUE",
            scope: :sandbox_env
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      data = DataExport.build(user)

      exported = Enum.find(data.custom_agents, &(&1.id == agent.id))
      assert exported, "expected the new custom agent in the export"
      assert exported.name == "Bot"
      assert exported.secret_names == ["openai_key"]

      json = Jason.encode!(data)
      refute json =~ "SUPER_SECRET_VALUE"
    end

    test "exports prompts, favorites, and drafts" do
      user = generate(user())

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{name: "P", content: "x", type: :user},
          actor: user
        )

      {:ok, conv} = Magus.Chat.create_conversation(%{title: "C"}, actor: user)

      {:ok, _draft} =
        Magus.Drafts.create_draft(conv.id, "Title", "content body", user.id, actor: user)

      data = DataExport.build(user)

      assert [%{id: pid, name: "P"}] = data.prompts
      assert pid == prompt.id

      # Drafts present
      assert [exported_draft] = data.drafts
      assert exported_draft.title == "Title"

      # Favorites struct is always present
      assert is_list(data.favorites.conversations)
      assert is_list(data.favorites.prompts)
    end
  end
end
