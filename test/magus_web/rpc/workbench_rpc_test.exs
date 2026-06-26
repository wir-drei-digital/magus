defmodule MagusWeb.Rpc.WorkbenchRpcTest do
  @moduledoc """
  Exercises the iteration-1/2 typescript_rpc exposure end to end through the
  HTTP RPC transport: tab-session lifecycle, conversation nav reads, and
  message history. These double as the compile/runtime verification for the
  `typescript_rpc` blocks on the Workbench, Workspaces, and Chat domains.
  """
  use MagusWeb.ConnCase, async: true

  import Magus.Generators
  import MagusWeb.LiveViewCase, only: [log_in_user: 2]

  # File creation via the policy path enforces storage limits, which need an
  # active subscription.
  defp subscribed_user do
    # Once the free plan exists, registration auto-subscribes new users — so
    # the explicit create below only matters for the first user of a test
    # run and is allowed to fail on the unique index afterwards.
    free_plan = ensure_free_plan()
    user = generate(user())

    case Magus.Usage.create_user_subscription(
           %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
           authorize?: false
         ) do
      {:ok, _subscription} -> :ok
      {:error, _already_subscribed} -> :ok
    end

    user
  end

  defp run(conn, user, body) do
    conn
    |> log_in_user(user)
    |> put_req_header("accept", "application/json")
    |> post("/rpc/run", body)
    |> json_response(200)
  end

  describe "tab session lifecycle" do
    test "get_or_create, open, activate, close", %{conn: conn} do
      user = generate(user())

      assert %{"success" => true, "data" => session} =
               run(conn, user, %{
                 "action" => "get_or_create_tab_session",
                 "input" => %{"userId" => user.id},
                 "fields" => ["id", "mode", "navFilter", "tabs", "activeTabId"]
               })

      assert session["mode"] == "chat"
      assert session["tabs"] == []

      assert %{"success" => true, "data" => opened} =
               run(conn, user, %{
                 "action" => "open_workbench_tab",
                 "identity" => session["id"],
                 "input" => %{"primary" => %{"type" => "conversation", "id" => "new"}},
                 "fields" => ["id", "tabs", "activeTabId"]
               })

      assert [tab] = opened["tabs"]
      assert opened["activeTabId"] == tab["id"]

      assert %{"success" => true, "data" => closed} =
               run(conn, user, %{
                 "action" => "close_workbench_tab",
                 "identity" => session["id"],
                 "input" => %{"tabId" => tab["id"]},
                 "fields" => ["tabs", "activeTabId"]
               })

      assert closed["tabs"] == []
    end

    test "replace_workbench_tabs trims to the given tabs (tabs-disabled path)", %{conn: conn} do
      user = generate(user())

      %{"success" => true, "data" => session} =
        run(conn, user, %{
          "action" => "get_or_create_tab_session",
          "input" => %{"userId" => user.id},
          "fields" => ["id"]
        })

      for id <- ["one", "two"] do
        assert %{"success" => true} =
                 run(conn, user, %{
                   "action" => "open_workbench_tab",
                   "identity" => session["id"],
                   "input" => %{"primary" => %{"type" => "conversation", "id" => id}},
                   "fields" => ["id"]
                 })
      end

      %{"success" => true, "data" => %{"tabs" => [_, active_tab], "activeTabId" => active_id}} =
        run(conn, user, %{
          "action" => "get_or_create_tab_session",
          "input" => %{"userId" => user.id},
          "fields" => ["id", "tabs", "activeTabId"]
        })

      assert active_tab["id"] == active_id

      assert %{"success" => true, "data" => replaced} =
               run(conn, user, %{
                 "action" => "replace_workbench_tabs",
                 "identity" => session["id"],
                 "input" => %{"tabs" => [active_tab], "activeTabId" => active_id},
                 "fields" => ["tabs", "activeTabId"]
               })

      assert [%{"id" => ^active_id}] = replaced["tabs"]
      assert replaced["activeTabId"] == active_id
    end

    test "users cannot touch another user's tab session", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())

      %{"success" => true, "data" => session} =
        run(conn, owner, %{
          "action" => "get_or_create_tab_session",
          "input" => %{"userId" => owner.id},
          "fields" => ["id"]
        })

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "open_workbench_tab",
                 "identity" => session["id"],
                 "input" => %{"primary" => %{"type" => "conversation", "id" => "new"}},
                 "fields" => ["id"]
               })
    end
  end

  describe "conversation nav reads" do
    test "my_conversations returns only the actor's conversations", %{conn: conn} do
      user = generate(user())
      other = generate(user())
      conversation = generate(conversation(actor: user))
      other_conversation = generate(conversation(actor: other))

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "my_conversations",
                 "fields" => ["id", "title", "chatMode", "updatedAt"]
               })

      ids = Enum.map(data, & &1["id"])
      assert conversation.id in ids
      refute other_conversation.id in ids
      assert Enum.all?(data, &Map.has_key?(&1, "updatedAt"))
    end

    test "my_workspaces lists the actor's workspaces", %{conn: conn} do
      user = generate(user())

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "my_workspaces",
                 "fields" => ["id", "name", "slug"]
               })

      assert is_list(data)
    end
  end

  describe "message history" do
    test "returns messages with timestamps for ordering", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      message =
        generate(message(actor: user, conversation_id: conversation.id, text: "Hello!"))

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "message_history",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id", "text", "source", "messageType", "status", "insertedAt"]
               })

      assert Enum.any?(data, &(&1["id"] == message.id))
      assert Enum.all?(data, &Map.has_key?(&1, "insertedAt"))
    end

    test "denies history for conversations the actor cannot read", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))
      generate(message(actor: owner, conversation_id: conversation.id, text: "secret"))

      assert %{"success" => true, "data" => data} =
               run(conn, stranger, %{
                 "action" => "message_history",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id", "text"]
               })

      assert data == []
    end
  end

  describe "send_user_message" do
    test "creates the user message and returns the persisted row", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "send_user_message",
                 "input" => %{"conversationId" => conversation.id, "text" => "Hello agent"},
                 "fields" => [
                   "id",
                   "text",
                   "source",
                   "role",
                   "messageType",
                   "status",
                   "insertedAt"
                 ]
               })

      assert data["text"] == "Hello agent"
      assert data["source"] == "user"
      assert data["role"] == "user"
      assert data["id"]

      assert {:ok, persisted} = Magus.Chat.get_message(data["id"], actor: user)
      assert persisted.conversation_id == conversation.id
    end

    test "denies sending into a conversation the actor cannot access", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "send_user_message",
                 "input" => %{"conversationId" => conversation.id, "text" => "sneaky"},
                 "fields" => ["id"]
               })
    end
  end

  describe "conversation lifecycle (iteration 3)" do
    test "create, rename, set mode, set model, archive", %{conn: conn} do
      user = generate(user())
      model = generate(model())

      assert %{"success" => true, "data" => created} =
               run(conn, user, %{
                 "action" => "create_conversation",
                 "input" => %{"title" => "Fresh chat"},
                 "fields" => ["id", "title", "chatMode"]
               })

      assert created["title"] == "Fresh chat"

      assert %{"success" => true, "data" => renamed} =
               run(conn, user, %{
                 "action" => "rename_conversation",
                 "identity" => created["id"],
                 "input" => %{"title" => "Better name"},
                 "fields" => ["id", "title"]
               })

      assert renamed["title"] == "Better name"

      assert %{"success" => true, "data" => moded} =
               run(conn, user, %{
                 "action" => "set_conversation_mode",
                 "identity" => created["id"],
                 "input" => %{"chatMode" => "reasoning"},
                 "fields" => ["id", "chatMode"]
               })

      assert moded["chatMode"] == "reasoning"

      assert %{"success" => true, "data" => modeled} =
               run(conn, user, %{
                 "action" => "set_conversation_model",
                 "identity" => created["id"],
                 "input" => %{"selectedModelId" => model.id},
                 "fields" => ["id", "selectedModelId"]
               })

      assert modeled["selectedModelId"] == model.id

      assert %{"success" => true} =
               run(conn, user, %{
                 "action" => "archive_conversation",
                 "identity" => created["id"],
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => remaining} =
               run(conn, user, %{
                 "action" => "my_conversations",
                 "fields" => ["id"]
               })

      refute created["id"] in Enum.map(remaining, & &1["id"])
    end

    test "strangers cannot rename or archive someone else's conversation", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "rename_conversation",
                 "identity" => conversation.id,
                 "input" => %{"title" => "hijack"},
                 "fields" => ["id"]
               })

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "archive_conversation",
                 "identity" => conversation.id,
                 "fields" => ["id"]
               })
    end

    test "update_settings round-trips sampling settings; strangers denied", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))
      model = generate(model())

      assert %{"success" => true, "data" => data} =
               run(conn, owner, %{
                 "action" => "update_conversation_settings",
                 "identity" => conversation.id,
                 "input" => %{"samplingSettings" => %{"temperature" => 0.4}},
                 "fields" => ["id", "samplingSettings"]
               })

      assert data["samplingSettings"]["temperature"] == 0.4

      for {action, input} <- [
            {"update_conversation_settings", %{"samplingSettings" => %{"temperature" => 1.0}}},
            {"set_conversation_model", %{"selectedModelId" => model.id}},
            {"set_conversation_mode", %{"chatMode" => "search"}}
          ] do
        assert %{"success" => false} =
                 run(conn, stranger, %{
                   "action" => action,
                   "identity" => conversation.id,
                   "input" => input,
                   "fields" => ["id"]
                 })
      end
    end
  end

  describe "message delete (iteration 3)" do
    test "the conversation owner can delete a message; strangers cannot", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))
      message = generate(message(actor: owner, conversation_id: conversation.id, text: "oops"))

      # Destroys run as a bulk destroy over the policy-filtered query: a
      # stranger matches zero rows and gets an idempotent empty success —
      # the record itself MUST survive.
      assert %{"success" => true, "data" => data} =
               run(conn, stranger, %{
                 "action" => "delete_message",
                 "identity" => message.id
               })

      assert data == %{}
      assert {:ok, _still_there} = Magus.Chat.get_message(message.id, actor: owner)

      assert %{"success" => true} =
               run(conn, owner, %{
                 "action" => "delete_message",
                 "identity" => message.id
               })

      assert {:error, _} = Magus.Chat.get_message(message.id, actor: owner)
    end

    test "toggle_message_disabled flips the context-exclusion flag", %{conn: conn} do
      owner = generate(user())
      conversation = generate(conversation(actor: owner))
      message = generate(message(actor: owner, conversation_id: conversation.id, text: "hide me"))

      assert %{"success" => true, "data" => %{"disabled" => true}} =
               run(conn, owner, %{
                 "action" => "toggle_message_disabled",
                 "identity" => message.id,
                 "fields" => ["id", "disabled"]
               })

      assert %{"success" => true, "data" => %{"disabled" => false}} =
               run(conn, owner, %{
                 "action" => "toggle_message_disabled",
                 "identity" => message.id,
                 "fields" => ["id", "disabled"]
               })
    end
  end

  describe "history view" do
    test "conversation_history paginates the actor's personal conversations", %{conn: conn} do
      user = generate(user())
      other = generate(user())
      for i <- 1..3, do: generate(conversation(actor: user, title: "Mine #{i}"))
      generate(conversation(actor: other, title: "Not mine"))

      trashed = generate(conversation(actor: user, title: "Trashed"))
      Magus.Chat.soft_delete_conversation!(trashed, actor: user)

      assert %{"success" => true, "data" => %{"results" => results, "hasMore" => true}} =
               run(conn, user, %{
                 "action" => "conversation_history",
                 "fields" => ["id", "title", "messageCount"],
                 "page" => %{"limit" => 2, "offset" => 0}
               })

      assert length(results) == 2

      assert %{"success" => true, "data" => %{"results" => rest, "hasMore" => false}} =
               run(conn, user, %{
                 "action" => "conversation_history",
                 "fields" => ["id", "title"],
                 "page" => %{"limit" => 2, "offset" => 2}
               })

      assert length(rest) == 1
      titles = Enum.map(results ++ rest, & &1["title"])
      refute "Not mine" in titles
      refute "Trashed" in titles
    end

    test "conversation_history searches titles and message contents", %{conn: conn} do
      user = generate(user())
      hit = generate(conversation(actor: user, title: "Plain title"))
      generate(message(actor: user, conversation_id: hit.id, text: "the quantum banana theory"))
      generate(conversation(actor: user, title: "Unrelated"))

      assert %{"success" => true, "data" => %{"results" => results}} =
               run(conn, user, %{
                 "action" => "conversation_history",
                 "input" => %{"query" => "quantum banana"},
                 "fields" => ["id", "title"],
                 "page" => %{"limit" => 10}
               })

      assert Enum.map(results, & &1["id"]) == [hit.id]
    end

    test "trash lifecycle: list, restore, permanently delete", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user, title: "Doomed"))
      Magus.Chat.soft_delete_conversation!(conversation, actor: user)

      assert %{"success" => true, "data" => [entry]} =
               run(conn, user, %{
                 "action" => "trashed_conversations",
                 "fields" => ["id", "title", "deletedAt"]
               })

      assert entry["id"] == conversation.id
      assert entry["deletedAt"]

      assert %{"success" => true, "data" => %{"deletedAt" => nil}} =
               run(conn, user, %{
                 "action" => "restore_conversation",
                 "identity" => conversation.id,
                 "fields" => ["id", "deletedAt"]
               })

      Magus.Chat.soft_delete_conversation!(conversation, actor: user, load: [])

      assert %{"success" => true} =
               run(conn, user, %{
                 "action" => "delete_conversation_permanently",
                 "identity" => conversation.id
               })

      assert %{"success" => true, "data" => []} =
               run(conn, user, %{
                 "action" => "trashed_conversations",
                 "fields" => ["id"]
               })
    end
  end

  describe "share links" do
    test "owner creates, lists, and revokes share links; strangers cannot create", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))

      assert %{"success" => true, "data" => link} =
               run(conn, owner, %{
                 "action" => "create_share_link",
                 "input" => %{
                   "conversationId" => conversation.id,
                   "accessType" => "public",
                   "label" => "For the blog"
                 },
                 "fields" => ["id", "token", "accessType", "label", "isActive"]
               })

      assert link["isActive"] == true
      assert link["token"] != nil

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "create_share_link",
                 "input" => %{"conversationId" => conversation.id, "accessType" => "public"},
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => [_listed]} =
               run(conn, owner, %{
                 "action" => "conversation_share_links",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id", "token"]
               })

      assert %{"success" => true, "data" => %{"isActive" => false}} =
               run(conn, owner, %{
                 "action" => "revoke_share_link",
                 "identity" => link["id"],
                 "fields" => ["id", "isActive"]
               })

      assert %{"success" => true, "data" => []} =
               run(conn, owner, %{
                 "action" => "conversation_share_links",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id"]
               })
    end

    test "multiplayer can be enabled and disabled over RPC", %{conn: conn} do
      owner = generate(user())
      conversation = generate(conversation(actor: owner))

      assert %{"success" => true, "data" => %{"isMultiplayer" => true}} =
               run(conn, owner, %{
                 "action" => "enable_conversation_multiplayer",
                 "identity" => conversation.id,
                 "fields" => ["id", "isMultiplayer"]
               })

      assert %{"success" => true, "data" => %{"isMultiplayer" => false}} =
               run(conn, owner, %{
                 "action" => "disable_conversation_multiplayer",
                 "identity" => conversation.id,
                 "fields" => ["id", "isMultiplayer"]
               })
    end
  end

  describe "participants" do
    test "members list with user info, role change, mute, remove", %{conn: conn} do
      owner = generate(user())
      participant = generate(user())
      conversation = generate(conversation(actor: owner))
      Magus.Chat.enable_multiplayer!(conversation, actor: owner)

      {:ok, member} =
        Magus.Chat.add_conversation_member(conversation.id, participant.id,
          actor: owner,
          authorize?: false
        )

      assert %{"success" => true, "data" => members} =
               run(conn, owner, %{
                 "action" => "conversation_members",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id", "role", "isMuted", %{"user" => ["id", "email"]}]
               })

      assert length(members) == 2
      assert Enum.any?(members, &(&1["user"]["id"] == participant.id))

      assert %{"success" => true, "data" => %{"role" => "observer"}} =
               run(conn, owner, %{
                 "action" => "change_member_role",
                 "identity" => member.id,
                 "input" => %{"role" => "observer"},
                 "fields" => ["id", "role"]
               })

      assert %{"success" => true, "data" => %{"isMuted" => true}} =
               run(conn, owner, %{
                 "action" => "mute_conversation_member",
                 "identity" => member.id,
                 "fields" => ["id", "isMuted"]
               })

      assert %{"success" => true} =
               run(conn, owner, %{
                 "action" => "remove_conversation_member",
                 "identity" => member.id
               })
    end

    test "email invitations: invite, list pending, cancel", %{conn: conn} do
      owner = generate(user())
      conversation = generate(conversation(actor: owner))
      Magus.Chat.enable_multiplayer!(conversation, actor: owner)

      assert %{"success" => true, "data" => invitation} =
               run(conn, owner, %{
                 "action" => "invite_to_conversation",
                 "input" => %{
                   "conversationId" => conversation.id,
                   "email" => "friend@example.com",
                   "role" => "member"
                 },
                 "fields" => ["id", "email", "role"]
               })

      assert invitation["email"] == "friend@example.com"

      assert %{"success" => true, "data" => [_pending]} =
               run(conn, owner, %{
                 "action" => "pending_conversation_invitations",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id", "email"]
               })

      assert %{"success" => true} =
               run(conn, owner, %{
                 "action" => "cancel_conversation_invitation",
                 "identity" => invitation["id"]
               })

      assert %{"success" => true, "data" => []} =
               run(conn, owner, %{
                 "action" => "pending_conversation_invitations",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id"]
               })
    end

    test "invite links: create, list, deactivate", %{conn: conn} do
      owner = generate(user())
      conversation = generate(conversation(actor: owner))
      Magus.Chat.enable_multiplayer!(conversation, actor: owner)

      assert %{"success" => true, "data" => link} =
               run(conn, owner, %{
                 "action" => "create_conversation_invite_link",
                 "input" => %{"conversationId" => conversation.id, "role" => "member"},
                 "fields" => ["id", "token", "role", "isActive"]
               })

      assert link["isActive"] == true

      assert %{"success" => true, "data" => [_listed]} =
               run(conn, owner, %{
                 "action" => "conversation_invite_links",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => %{"isActive" => false}} =
               run(conn, owner, %{
                 "action" => "deactivate_conversation_invite_link",
                 "identity" => link["id"],
                 "fields" => ["id", "isActive"]
               })
    end
  end

  describe "models and agents (iteration 3)" do
    test "list_active_models returns active models with capability flags", %{conn: conn} do
      user = generate(user())
      model = generate(model())
      inactive = generate(model(active?: false))

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "list_active_models",
                 "fields" => ["id", "name", "supportsTools", "inputCost", "outputCost"]
               })

      ids = Enum.map(data, & &1["id"])
      assert model.id in ids
      refute inactive.id in ids
      assert Enum.all?(data, &Map.has_key?(&1, "supportsTools"))
    end

    test "my_agents returns the actor's agents for mention autocomplete", %{conn: conn} do
      user = generate(user())
      agent = custom_agent(user, %{name: "Researcher"})

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "my_agents",
                 "fields" => ["id", "name", "handle", "icon", "description", "isDefault"]
               })

      assert Enum.any?(data, &(&1["id"] == agent.id and &1["handle"] != nil))
    end
  end

  describe "brain page companion (iteration 4)" do
    setup do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      %{user: user, brain: brain}
    end

    test "get_brain_page returns the markdown body", %{conn: conn, user: user, brain: brain} do
      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          title: "Roadmap",
          content: "# Roadmap\n\nShip iteration 4."
        )

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "get_brain_page",
                 "getBy" => %{"id" => page.id},
                 "fields" => ["id", "title", "icon", "body", "updatedAt"]
               })

      assert data["id"] == page.id
      assert data["title"] == "Roadmap"
      assert data["body"] =~ "Ship iteration 4."
      assert Map.has_key?(data, "updatedAt")
    end

    test "strangers cannot read another user's brain page", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      stranger = generate(user())
      page = brain_page(brain_id: brain.id, user_id: user.id)

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "get_brain_page",
                 "getBy" => %{"id" => page.id},
                 "fields" => ["id"]
               })
    end

    test "list_page_backlinks returns linking pages with titles", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      target = brain_page(brain_id: brain.id, user_id: user.id, title: "Target Page Xy")

      _linker =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          title: "Linker Page",
          content: "See [[Target Page Xy]] for details."
        )

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "list_page_backlinks",
                 "input" => %{"pageId" => target.id},
                 "fields" => [
                   "id",
                   "targetTitleAtLinkTime",
                   %{"sourcePage" => ["id", "title", "icon"]}
                 ]
               })

      assert [link] = data
      assert link["targetTitleAtLinkTime"] == "Target Page Xy"
      assert link["sourcePage"]["title"] == "Linker Page"
    end

    test "list_page_sources returns sources in document order", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      page = brain_page(brain_id: brain.id, user_id: user.id)
      source = brain_source(brain_id: brain.id, user_id: user.id, title: "Paper")

      {:ok, _} =
        Magus.Brain.PageSource
        |> Ash.Changeset.for_create(:create, %{
          page_id: page.id,
          source_id: source.id,
          position: 0
        })
        |> Ash.create(authorize?: false)

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "list_page_sources",
                 "input" => %{"pageId" => page.id},
                 "fields" => [
                   "id",
                   "position",
                   %{"source" => ["id", "url", "title", "sourceType", "ingestStatus"]}
                 ]
               })

      assert [entry] = data
      assert entry["source"]["title"] == "Paper"
      assert entry["source"]["url"] =~ "https://"
    end

    test "list_brain_page_versions returns history; strangers are denied", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      page = brain_page(brain_id: brain.id, user_id: user.id, content: "v1 body")
      replace_page_body(page, "v2 body", user)

      assert %{"success" => true, "data" => versions} =
               run(conn, user, %{
                 "action" => "list_brain_page_versions",
                 "input" => %{"pageId" => page.id}
               })

      assert is_list(versions)
      assert length(versions) >= 1
      assert Enum.all?(versions, &Map.has_key?(&1, "version_id"))

      stranger = generate(user())

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "list_brain_page_versions",
                 "input" => %{"pageId" => page.id}
               })
    end
  end

  describe "threads (iteration 4)" do
    test "create_thread branches at a message and conversation_threads lists it", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))
      message = generate(message(actor: user, conversation_id: conversation.id, text: "Branch"))

      assert %{"success" => true, "data" => thread} =
               run(conn, user, %{
                 "action" => "create_thread",
                 "input" => %{
                   "parentConversationId" => conversation.id,
                   "branchedAtMessageId" => message.id
                 },
                 "fields" => ["id", "isThread", "parentConversationId", "branchedAtMessageId"]
               })

      assert thread["isThread"] == true
      assert thread["parentConversationId"] == conversation.id
      assert thread["branchedAtMessageId"] == message.id

      assert %{"success" => true, "data" => threads} =
               run(conn, user, %{
                 "action" => "conversation_threads",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id", "branchedAtMessageId", "insertedAt"]
               })

      assert Enum.any?(threads, &(&1["id"] == thread["id"]))
    end

    test "strangers cannot branch threads off another user's conversation", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))
      message = generate(message(actor: owner, conversation_id: conversation.id, text: "Hi"))

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "create_thread",
                 "input" => %{
                   "parentConversationId" => conversation.id,
                   "branchedAtMessageId" => message.id
                 },
                 "fields" => ["id"]
               })
    end

    test "conversation_threads is policy-filtered: strangers see nothing", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))
      message = generate(message(actor: owner, conversation_id: conversation.id, text: "Hi"))

      {:ok, _thread} =
        Magus.Chat.create_thread(
          %{parent_conversation_id: conversation.id, branched_at_message_id: message.id},
          actor: owner
        )

      assert %{"success" => true, "data" => []} =
               run(conn, stranger, %{
                 "action" => "conversation_threads",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id"]
               })
    end
  end

  describe "drafts (iteration 4)" do
    test "get_draft and conversation_drafts return the actor's drafts", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, draft} =
        Magus.Drafts.create_draft(conversation.id, "Notes", "Hello world", user.id, actor: user)

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "get_draft",
                 "getBy" => %{"id" => draft.id},
                 "fields" => ["id", "title", "content", "version", "updatedAt", "conversationId"]
               })

      assert data["id"] == draft.id
      assert data["title"] == "Notes"
      assert %{"type" => "doc"} = data["content"]
      assert data["conversationId"] == conversation.id

      assert %{"success" => true, "data" => listed} =
               run(conn, user, %{
                 "action" => "conversation_drafts",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id", "title"]
               })

      assert Enum.any?(listed, &(&1["id"] == draft.id))
    end

    test "strangers cannot read another user's draft", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))

      {:ok, draft} =
        Magus.Drafts.create_draft(conversation.id, "Private", "Secret", owner.id, actor: owner)

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "get_draft",
                 "getBy" => %{"id" => draft.id},
                 "fields" => ["id"]
               })
    end
  end

  describe "files browser (iteration 5)" do
    @file_fields [
      "id",
      "name",
      "type",
      "source",
      "mimeType",
      "fileSize",
      "filePath",
      "isTemplate",
      "status",
      "updatedAt",
      "folderId"
    ]

    test "my_library_files lists only the actor's personal library", %{conn: conn} do
      user = subscribed_user()
      other = subscribed_user()
      file = generate(file(actor: user))
      other_file = generate(file(actor: other))

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{"action" => "my_library_files", "fields" => @file_fields})

      ids = Enum.map(data, & &1["id"])
      assert file.id in ids
      refute other_file.id in ids
      assert Enum.all?(data, &Map.has_key?(&1, "filePath"))
    end

    test "rename, trash, and trash listing round-trip", %{conn: conn} do
      user = subscribed_user()
      file = generate(file(actor: user))

      assert %{"success" => true, "data" => renamed} =
               run(conn, user, %{
                 "action" => "rename_file",
                 "identity" => file.id,
                 "input" => %{"name" => "report-final.txt"},
                 "fields" => ["id", "name"]
               })

      assert renamed["name"] == "report-final.txt"

      assert %{"success" => true} =
               run(conn, user, %{
                 "action" => "trash_file",
                 "identity" => file.id,
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => library} =
               run(conn, user, %{"action" => "my_library_files", "fields" => ["id"]})

      refute Enum.any?(library, &(&1["id"] == file.id))

      assert %{"success" => true, "data" => trash} =
               run(conn, user, %{"action" => "trash_files", "fields" => ["id"]})

      assert Enum.any?(trash, &(&1["id"] == file.id))
    end

    test "strangers cannot rename or trash another user's file", %{conn: conn} do
      owner = subscribed_user()
      stranger = generate(user())
      file = generate(file(actor: owner))

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "rename_file",
                 "identity" => file.id,
                 "input" => %{"name" => "hijacked"},
                 "fields" => ["id"]
               })

      assert {:ok, persisted} = Magus.Files.get_file(file.id, actor: owner)
      assert persisted.name == file.name
    end

    test "moving a file into a conversations folder promotes its kind to mixed", %{conn: conn} do
      user = subscribed_user()
      folder = generate(folder(actor: user, kind: :conversations))
      file = generate(file(actor: user))

      assert %{"success" => true, "data" => moved} =
               run(conn, user, %{
                 "action" => "move_file",
                 "identity" => file.id,
                 "input" => %{"folderId" => folder.id},
                 "fields" => ["id", "folderId"]
               })

      assert moved["folderId"] == folder.id

      assert %{"success" => true, "data" => promoted} =
               run(conn, user, %{
                 "action" => "get_folder",
                 "getBy" => %{"id" => folder.id},
                 "fields" => ["id", "kind"]
               })

      assert promoted["kind"] == "mixed"

      assert %{"success" => true, "data" => in_folder} =
               run(conn, user, %{
                 "action" => "folder_files",
                 "input" => %{"folderId" => folder.id},
                 "fields" => ["id"]
               })

      assert Enum.any?(in_folder, &(&1["id"] == file.id))
    end
  end

  describe "folders (iteration 5)" do
    test "create, list children, rename, move, delete", %{conn: conn} do
      user = generate(user())

      assert %{"success" => true, "data" => parent} =
               run(conn, user, %{
                 "action" => "create_folder",
                 "input" => %{"name" => "Projects", "kind" => "files"},
                 "fields" => ["id", "name", "kind"]
               })

      assert %{"success" => true, "data" => child} =
               run(conn, user, %{
                 "action" => "create_folder",
                 "input" => %{"name" => "Q2", "kind" => "files", "parentId" => parent["id"]},
                 "fields" => ["id", "name", "parentId"]
               })

      assert child["parentId"] == parent["id"]

      assert %{"success" => true, "data" => children} =
               run(conn, user, %{
                 "action" => "folder_children",
                 "input" => %{"parentId" => parent["id"]},
                 "fields" => ["id", "name"]
               })

      assert Enum.any?(children, &(&1["id"] == child["id"]))

      assert %{"success" => true, "data" => renamed} =
               run(conn, user, %{
                 "action" => "rename_folder",
                 "identity" => child["id"],
                 "input" => %{"name" => "Q3"},
                 "fields" => ["id", "name"]
               })

      assert renamed["name"] == "Q3"

      assert %{"success" => true, "data" => moved} =
               run(conn, user, %{
                 "action" => "move_folder",
                 "identity" => child["id"],
                 "input" => %{"parentId" => nil},
                 "fields" => ["id", "parentId"]
               })

      assert moved["parentId"] == nil

      assert %{"success" => true} =
               run(conn, user, %{
                 "action" => "delete_folder",
                 "identity" => child["id"]
               })

      assert %{"success" => true, "data" => folders} =
               run(conn, user, %{
                 "action" => "my_folders",
                 "input" => %{"kinds" => ["files", "mixed"]},
                 "fields" => ["id", "name", "kind", "parentId"]
               })

      ids = Enum.map(folders, & &1["id"])
      assert parent["id"] in ids
      refute child["id"] in ids
    end

    test "strangers cannot rename another user's folder", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      folder = generate(folder(actor: owner, kind: :files))

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "rename_folder",
                 "identity" => folder.id,
                 "input" => %{"name" => "hijacked"},
                 "fields" => ["id"]
               })
    end
  end

  describe "conversation favorites (parity pass)" do
    test "favorite, list, and unfavorite round-trip", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      assert %{"success" => true, "data" => favorite} =
               run(conn, user, %{
                 "action" => "favorite_conversation",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id", "conversationId"]
               })

      assert favorite["conversationId"] == conversation.id

      assert %{"success" => true, "data" => favorites} =
               run(conn, user, %{
                 "action" => "my_favorite_conversations",
                 "fields" => ["id", "isFavorited"]
               })

      assert Enum.any?(favorites, &(&1["id"] == conversation.id and &1["isFavorited"]))

      assert %{"success" => true} =
               run(conn, user, %{
                 "action" => "unfavorite_conversation",
                 "identity" => favorite["id"]
               })

      assert %{"success" => true, "data" => []} =
               run(conn, user, %{"action" => "my_favorite_conversations", "fields" => ["id"]})
    end

    test "strangers cannot favorite an unreadable conversation", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "favorite_conversation",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id"]
               })
    end
  end

  describe "prompts (iteration 6)" do
    test "create, list, update, favorite, tag round-trip", %{conn: conn} do
      user = generate(user())

      assert %{"success" => true, "data" => created} =
               run(conn, user, %{
                 "action" => "create_prompt",
                 "input" => %{
                   "name" => "Review checklist",
                   "content" => "Review the following code…",
                   "type" => "user"
                 },
                 "fields" => ["id", "name", "content", "type"]
               })

      assert created["type"] == "user"

      assert %{"success" => true, "data" => listed} =
               run(conn, user, %{
                 "action" => "my_prompts",
                 "fields" => ["id", "name", "isFavorited", "isSharedToWorkspace"]
               })

      assert Enum.any?(listed, &(&1["id"] == created["id"]))

      assert %{"success" => true, "data" => updated} =
               run(conn, user, %{
                 "action" => "update_prompt",
                 "identity" => created["id"],
                 "input" => %{"name" => "Review checklist v2"},
                 "fields" => ["id", "name"]
               })

      assert updated["name"] == "Review checklist v2"

      assert %{"success" => true} =
               run(conn, user, %{
                 "action" => "favorite_prompt",
                 "input" => %{"promptId" => created["id"]},
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => favorites} =
               run(conn, user, %{"action" => "my_favorite_prompts", "fields" => ["id"]})

      assert Enum.any?(favorites, &(&1["id"] == created["id"]))

      {:ok, tag} =
        Magus.Library.Tag
        |> Ash.Changeset.for_create(:get_or_create, %{name: "review"})
        |> Ash.create(actor: user)

      assert %{"success" => true, "data" => tagged} =
               run(conn, user, %{
                 "action" => "add_prompt_tags",
                 "identity" => created["id"],
                 "input" => %{"tagIds" => [tag.id]},
                 "fields" => ["id", %{"tags" => ["id", "name"]}]
               })

      assert Enum.any?(tagged["tags"], &(&1["id"] == tag.id))
    end

    test "strangers cannot update or read another user's private prompt", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{name: "Private", content: "Secret prompt", type: :user},
          actor: owner
        )

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "update_prompt",
                 "identity" => prompt.id,
                 "input" => %{"name" => "hijacked"},
                 "fields" => ["id"]
               })

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "get_prompt",
                 "getBy" => %{"id" => prompt.id},
                 "fields" => ["id"]
               })
    end
  end

  describe "agents (iteration 6)" do
    test "create, get config, update sections, secrets", %{conn: conn} do
      user = generate(user())

      assert %{"success" => true, "data" => created} =
               run(conn, user, %{
                 "action" => "create_custom_agent",
                 "input" => %{"name" => "Research Agent", "instructions" => "Dig deep."},
                 "fields" => ["id", "name", "handle", "instructions"]
               })

      assert created["handle"]

      assert %{"success" => true, "data" => detail} =
               run(conn, user, %{
                 "action" => "get_custom_agent",
                 "getBy" => %{"id" => created["id"]},
                 "fields" => [
                   "id",
                   "instructions",
                   "chatMode",
                   "maxIterations",
                   "isPaused",
                   "heartbeatEnabled",
                   "canReadGlobalMemories",
                   "updatedAt"
                 ]
               })

      assert Map.has_key?(detail, "heartbeatEnabled")

      assert %{"success" => true, "data" => updated} =
               run(conn, user, %{
                 "action" => "update_custom_agent",
                 "identity" => created["id"],
                 "input" => %{"instructions" => "Dig deeper.", "isPaused" => true},
                 "fields" => ["id", "instructions", "isPaused"]
               })

      assert updated["instructions"] == "Dig deeper."
      assert updated["isPaused"] == true

      assert %{"success" => true, "data" => secret} =
               run(conn, user, %{
                 "action" => "create_agent_secret",
                 "input" => %{
                   "customAgentId" => created["id"],
                   "key" => "GITHUB_TOKEN",
                   "value" => "ghp_secret",
                   "scope" => "sandbox_env"
                 },
                 "fields" => ["id", "key", "scope"]
               })

      assert secret["key"] == "GITHUB_TOKEN"
      refute Map.has_key?(secret, "value")

      assert %{"success" => true, "data" => secrets} =
               run(conn, user, %{
                 "action" => "agent_secrets",
                 "input" => %{"customAgentId" => created["id"]},
                 "fields" => ["id", "key", "scope", "description"]
               })

      assert Enum.any?(secrets, &(&1["key"] == "GITHUB_TOKEN"))
    end

    test "activity and inbox reads are scoped to the owner", %{conn: conn} do
      user = generate(user())
      stranger = generate(user())
      agent = custom_agent(user, %{name: "Watcher"})

      {:ok, _log} =
        Magus.Agents.create_activity_log(
          %{
            agent_id: agent.id,
            activity_type: :run_completed,
            summary: "Did the thing"
          },
          actor: user
        )

      assert %{"success" => true, "data" => activity} =
               run(conn, user, %{
                 "action" => "agent_activity",
                 "input" => %{"agentId" => agent.id},
                 "fields" => ["id", "activityType", "summary", "insertedAt"]
               })

      assert Enum.any?(activity, &(&1["summary"] == "Did the thing"))

      assert %{"success" => true, "data" => []} =
               run(conn, stranger, %{
                 "action" => "agent_activity",
                 "input" => %{"agentId" => agent.id},
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => events} =
               run(conn, user, %{
                 "action" => "agent_inbox_events",
                 "input" => %{"agentId" => agent.id},
                 "fields" => ["id", "eventType", "status", "title"]
               })

      assert is_list(events)
    end

    test "strangers cannot update another user's agent", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      agent = custom_agent(owner, %{name: "Mine"})

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "update_custom_agent",
                 "identity" => agent.id,
                 "input" => %{"instructions" => "hijacked"},
                 "fields" => ["id"]
               })
    end

    test "trigger_agent_run enqueues a manual run for the owner only", %{conn: conn} do
      user = generate(user())
      agent = custom_agent(user, %{name: "Runner"})

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "trigger_agent_run",
                 "input" => %{"agentId" => agent.id}
               })

      assert data["run_id"]

      stranger = generate(user())

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "trigger_agent_run",
                 "input" => %{"agentId" => agent.id}
               })
    end
  end

  describe "brain editing (iteration 7)" do
    setup do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      %{user: user, brain: brain}
    end

    test "page tree: create, list roots and children, rename", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      assert %{"success" => true, "data" => root} =
               run(conn, user, %{
                 "action" => "create_brain_page",
                 "input" => %{"brainId" => brain.id, "title" => "Projects"},
                 "fields" => ["id", "title", "parentPageId", "lockVersion"]
               })

      assert root["lockVersion"] == 0

      assert %{"success" => true, "data" => child} =
               run(conn, user, %{
                 "action" => "create_brain_page",
                 "input" => %{
                   "brainId" => brain.id,
                   "title" => "Q3",
                   "parentPageId" => root["id"]
                 },
                 "fields" => ["id", "title", "parentPageId"]
               })

      assert child["parentPageId"] == root["id"]

      assert %{"success" => true, "data" => roots} =
               run(conn, user, %{
                 "action" => "root_brain_pages",
                 "input" => %{"brainId" => brain.id},
                 "fields" => ["id", "title"]
               })

      root_ids = Enum.map(roots, & &1["id"])
      assert root["id"] in root_ids
      refute child["id"] in root_ids

      assert %{"success" => true, "data" => children} =
               run(conn, user, %{
                 "action" => "brain_page_children",
                 "input" => %{"parentPageId" => root["id"]},
                 "fields" => ["id", "title"]
               })

      assert Enum.any?(children, &(&1["id"] == child["id"]))

      assert %{"success" => true, "data" => renamed} =
               run(conn, user, %{
                 "action" => "rename_brain_page",
                 "identity" => child["id"],
                 "input" => %{"title" => "Q4"},
                 "fields" => ["id", "title"]
               })

      assert renamed["title"] == "Q4"
    end

    test "update_body round-trip and stale-version conflict", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      page = brain_page(brain_id: brain.id, user_id: user.id, content: "v1")

      {:ok, current} = Magus.Brain.get_page(page.id, actor: user)

      assert %{"success" => true, "data" => updated} =
               run(conn, user, %{
                 "action" => "update_brain_page_body",
                 "identity" => page.id,
                 "input" => %{"body" => "# v2", "baseVersion" => current.lock_version},
                 "fields" => ["id", "body", "lockVersion"]
               })

      assert updated["body"] == "# v2"
      assert updated["lockVersion"] == current.lock_version + 1

      # Saving against the OLD version must fail with a conflict error.
      assert %{"success" => false, "errors" => [error | _]} =
               run(conn, user, %{
                 "action" => "update_brain_page_body",
                 "identity" => page.id,
                 "input" => %{"body" => "# stale", "baseVersion" => current.lock_version},
                 "fields" => ["id"]
               })

      assert error["type"] == "version_conflict"
      assert error["message"] =~ ~r/version|conflict|stale|edited/i

      {:ok, persisted} = Magus.Brain.get_page(page.id, actor: user)
      assert persisted.body == "# v2"
    end

    test "prosemirror load + save round-trip with conflict", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      page = brain_page(brain_id: brain.id, user_id: user.id, content: "# Hello")

      # Load: the calc converts markdown → ProseMirror JSON server-side.
      assert %{"success" => true, "data" => loaded} =
               run(conn, user, %{
                 "action" => "get_brain_page",
                 "getBy" => %{"id" => page.id},
                 "fields" => ["id", "lockVersion", "prosemirror"]
               })

      assert %{"type" => "doc"} = loaded["prosemirror"]

      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "heading",
            "attrs" => %{"level" => 1},
            "content" => [%{"type" => "text", "text" => "Saved rich"}]
          },
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "text" => "From TipTap."}]
          }
        ]
      }

      assert %{"success" => true, "data" => saved} =
               run(conn, user, %{
                 "action" => "save_brain_page_prosemirror",
                 "input" => %{
                   "pageId" => page.id,
                   "prosemirror" => doc,
                   "baseVersion" => loaded["lockVersion"]
                 }
               })

      assert saved["lock_version"] == loaded["lockVersion"] + 1

      {:ok, persisted} = Magus.Brain.get_page(page.id, actor: user)
      assert persisted.body =~ "# Saved rich"
      assert persisted.body =~ "From TipTap."

      # Stale base version → typed conflict.
      assert %{"success" => false, "errors" => [error | _]} =
               run(conn, user, %{
                 "action" => "save_brain_page_prosemirror",
                 "input" => %{
                   "pageId" => page.id,
                   "prosemirror" => doc,
                   "baseVersion" => loaded["lockVersion"]
                 }
               })

      assert error["type"] == "version_conflict"
    end

    test "trash and restore round-trip", %{conn: conn, user: user, brain: brain} do
      page = brain_page(brain_id: brain.id, user_id: user.id, title: "Doomed")

      assert %{"success" => true} =
               run(conn, user, %{
                 "action" => "trash_brain_page",
                 "identity" => page.id,
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => trashed} =
               run(conn, user, %{
                 "action" => "trashed_brain_pages",
                 "input" => %{"workspaceId" => nil},
                 "fields" => ["id", "title"]
               })

      assert Enum.any?(trashed, &(&1["id"] == page.id))

      assert %{"success" => true} =
               run(conn, user, %{
                 "action" => "restore_brain_page",
                 "identity" => page.id,
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => restored} =
               run(conn, user, %{
                 "action" => "get_brain_page",
                 "getBy" => %{"id" => page.id},
                 "fields" => ["id", "title"]
               })

      assert restored["title"] == "Doomed"
    end

    test "strangers cannot restore another user's trashed page", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      page = brain_page(brain_id: brain.id, user_id: user.id)
      {:ok, _} = Magus.Brain.soft_delete_page(page, actor: user)

      stranger = generate(user())

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "restore_brain_page",
                 "identity" => page.id,
                 "fields" => ["id"]
               })
    end

    test "my_brains lists and strangers cannot edit pages", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      assert %{"success" => true, "data" => brains} =
               run(conn, user, %{
                 "action" => "my_brains",
                 "fields" => ["id", "title", "icon", "workspaceId"]
               })

      assert Enum.any?(brains, &(&1["id"] == brain.id))

      stranger = generate(user())
      page = brain_page(brain_id: brain.id, user_id: user.id, content: "private")
      {:ok, current} = Magus.Brain.get_page(page.id, actor: user)

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "update_brain_page_body",
                 "identity" => page.id,
                 "input" => %{"body" => "hijack", "baseVersion" => current.lock_version},
                 "fields" => ["id"]
               })
    end
  end

  describe "right rail (parity)" do
    test "conversation_files lists only files attached to the conversation", %{conn: conn} do
      user = subscribed_user()
      conversation = generate(conversation(actor: user))
      attached = generate(file(actor: user, conversation_id: conversation.id))
      library_file = generate(file(actor: user))

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "conversation_files",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id", "name"]
               })

      ids = Enum.map(data, & &1["id"])
      assert attached.id in ids
      refute library_file.id in ids
    end

    test "strangers see no files for another user's conversation", %{conn: conn} do
      owner = subscribed_user()
      stranger = subscribed_user()
      conversation = generate(conversation(actor: owner))
      _attached = generate(file(actor: owner, conversation_id: conversation.id))

      assert %{"success" => true, "data" => []} =
               run(conn, stranger, %{
                 "action" => "conversation_files",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id"]
               })
    end

    test "delete_draft removes the actor's draft and denies strangers", %{conn: conn} do
      user = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, draft} =
        Magus.Drafts.create_draft(conversation.id, "Notes", "Body", user.id, actor: user)

      assert %{"success" => false} =
               run(conn, stranger, %{"action" => "delete_draft", "identity" => draft.id})

      assert %{"success" => true} =
               run(conn, user, %{"action" => "delete_draft", "identity" => draft.id})

      assert %{"success" => false} =
               run(conn, user, %{
                 "action" => "get_draft",
                 "getBy" => %{"id" => draft.id},
                 "fields" => ["id"]
               })
    end

    test "system prompt activate/deactivate round-trip", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      %{"success" => true, "data" => prompt} =
        run(conn, user, %{
          "action" => "create_prompt",
          "input" => %{
            "name" => "Pirate mode",
            "content" => "Answer as a pirate.",
            "type" => "system"
          },
          "fields" => ["id", "name"]
        })

      assert %{"success" => true, "data" => activated} =
               run(conn, user, %{
                 "action" => "activate_conversation_prompt",
                 "identity" => conversation.id,
                 "input" => %{"promptId" => prompt["id"]},
                 "fields" => ["id", %{"activeSystemPrompt" => ["id", "name"]}]
               })

      assert activated["activeSystemPrompt"]["id"] == prompt["id"]
      assert activated["activeSystemPrompt"]["name"] == "Pirate mode"

      assert %{"success" => true, "data" => deactivated} =
               run(conn, user, %{
                 "action" => "deactivate_conversation_prompt",
                 "identity" => conversation.id,
                 "fields" => ["id", %{"activeSystemPrompt" => ["id"]}]
               })

      assert deactivated["activeSystemPrompt"] == nil
    end

    test "owners cannot link another user's private prompt by UUID", %{conn: conn} do
      owner = generate(user())
      other = generate(user())
      conversation = generate(conversation(actor: owner))

      %{"success" => true, "data" => foreign_prompt} =
        run(conn, other, %{
          "action" => "create_prompt",
          "input" => %{"name" => "Private", "content" => "Secret", "type" => "system"},
          "fields" => ["id"]
        })

      assert %{"success" => false} =
               run(conn, owner, %{
                 "action" => "activate_conversation_prompt",
                 "identity" => conversation.id,
                 "input" => %{"promptId" => foreign_prompt["id"]},
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => %{"activeSystemPrompt" => nil}} =
               run(conn, owner, %{
                 "action" => "get_conversation",
                 "getBy" => %{"id" => conversation.id},
                 "fields" => ["id", %{"activeSystemPrompt" => ["id"]}]
               })
    end

    test "strangers cannot activate prompts on another user's conversation", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))

      %{"success" => true, "data" => prompt} =
        run(conn, stranger, %{
          "action" => "create_prompt",
          "input" => %{"name" => "X", "content" => "Y", "type" => "system"},
          "fields" => ["id"]
        })

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "activate_conversation_prompt",
                 "identity" => conversation.id,
                 "input" => %{"promptId" => prompt["id"]},
                 "fields" => ["id"]
               })
    end

    test "reset_conversation_settings clears system prompt and sampling", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      assert %{"success" => true, "data" => updated} =
               run(conn, user, %{
                 "action" => "update_conversation_settings",
                 "identity" => conversation.id,
                 "input" => %{
                   "systemPrompt" => "Be terse.",
                   "samplingSettings" => %{"temperature" => 0.5, "top_k" => 40}
                 },
                 "fields" => ["id", "systemPrompt", "samplingSettings"]
               })

      assert updated["systemPrompt"] == "Be terse."
      assert updated["samplingSettings"]["temperature"] == 0.5

      assert %{"success" => true, "data" => reset} =
               run(conn, user, %{
                 "action" => "reset_conversation_settings",
                 "identity" => conversation.id,
                 "fields" => ["id", "systemPrompt", "samplingSettings"]
               })

      assert reset["systemPrompt"] == nil
      assert reset["samplingSettings"] == nil
    end

    test "jobs: list, pause, resume, stop lifecycle", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, job} =
        Magus.Workflows.create_job(
          conversation.id,
          %{
            name: "Daily digest",
            trigger_prompt: "Summarize the day",
            schedule_type: :one_time,
            scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          # Fixture setup: user job creation requires a multiplayer member row
          # (jobs are normally created by the AI agent). The RPC calls below
          # are the authorization under test.
          authorize?: false,
          actor: user
        )

      job_fields = ["id", "name", "status", "scheduleType", "nextRunAt"]

      assert %{"success" => true, "data" => [listed]} =
               run(conn, user, %{
                 "action" => "conversation_jobs",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => job_fields
               })

      assert listed["id"] == job.id
      assert listed["status"] == "active"

      assert %{"success" => true, "data" => %{"status" => "paused"}} =
               run(conn, user, %{
                 "action" => "pause_job",
                 "identity" => job.id,
                 "fields" => job_fields
               })

      assert %{"success" => true, "data" => %{"status" => "active"}} =
               run(conn, user, %{
                 "action" => "resume_job",
                 "identity" => job.id,
                 "fields" => job_fields
               })

      assert %{"success" => true, "data" => %{"status" => "stopped"}} =
               run(conn, user, %{
                 "action" => "stop_job",
                 "identity" => job.id,
                 "fields" => job_fields
               })

      assert %{"success" => true, "data" => []} =
               run(conn, user, %{
                 "action" => "conversation_jobs",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id"]
               })
    end

    test "strangers cannot control another user's jobs", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))

      {:ok, job} =
        Magus.Workflows.create_job(
          conversation.id,
          %{
            name: "Private job",
            trigger_prompt: "x",
            schedule_type: :one_time,
            scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          authorize?: false,
          actor: owner
        )

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "pause_job",
                 "identity" => job.id,
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => []} =
               run(conn, stranger, %{
                 "action" => "conversation_jobs",
                 "input" => %{"conversationId" => conversation.id},
                 "fields" => ["id"]
               })
    end
  end

  describe "chat nav (parity)" do
    test "personal_conversations excludes workspace conversations", %{conn: conn} do
      user = generate(user())
      workspace = generate(workspace(actor: user))
      personal = generate(conversation(actor: user))
      workspace_conv = generate(conversation(actor: user, workspace_id: workspace.id))

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "personal_conversations",
                 "fields" => ["id", "folderId", "isSharedToWorkspace", "lastMessageAt"]
               })

      ids = Enum.map(data, & &1["id"])
      assert personal.id in ids
      refute workspace_conv.id in ids
    end

    test "share/unshare a workspace conversation round-trips", %{conn: conn} do
      user = generate(user())
      workspace = generate(workspace(actor: user))
      conversation = generate(conversation(actor: user, workspace_id: workspace.id))

      assert %{"success" => true, "data" => %{"isSharedToWorkspace" => true}} =
               run(conn, user, %{
                 "action" => "share_conversation_to_team",
                 "identity" => conversation.id,
                 "fields" => ["id", "isSharedToWorkspace"]
               })

      assert %{"success" => true, "data" => %{"isSharedToWorkspace" => false}} =
               run(conn, user, %{
                 "action" => "unshare_conversation_from_team",
                 "identity" => conversation.id,
                 "fields" => ["id", "isSharedToWorkspace"]
               })
    end

    test "sharing a personal conversation is rejected", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      assert %{"success" => false} =
               run(conn, user, %{
                 "action" => "share_conversation_to_team",
                 "identity" => conversation.id,
                 "fields" => ["id"]
               })
    end

    test "move_conversation_to_folder files and unfiles", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      %{"success" => true, "data" => folder} =
        run(conn, user, %{
          "action" => "create_folder",
          "input" => %{"name" => "Projects", "kind" => "conversations"},
          "fields" => ["id", "name", "kind"]
        })

      assert %{"success" => true, "data" => %{"folderId" => folder_id}} =
               run(conn, user, %{
                 "action" => "move_conversation_to_folder",
                 "identity" => conversation.id,
                 "input" => %{"folderId" => folder["id"]},
                 "fields" => ["id", "folderId"]
               })

      assert folder_id == folder["id"]

      assert %{"success" => true, "data" => %{"folderId" => nil}} =
               run(conn, user, %{
                 "action" => "move_conversation_to_folder",
                 "identity" => conversation.id,
                 "input" => %{"folderId" => nil},
                 "fields" => ["id", "folderId"]
               })
    end

    test "cannot move a conversation into another user's folder", %{conn: conn} do
      owner = generate(user())
      other = generate(user())
      conversation = generate(conversation(actor: owner))
      foreign_folder = generate(folder(actor: other, kind: :conversations))

      assert %{"success" => false} =
               run(conn, owner, %{
                 "action" => "move_conversation_to_folder",
                 "identity" => conversation.id,
                 "input" => %{"folderId" => foreign_folder.id},
                 "fields" => ["id", "folderId"]
               })
    end

    test "folder expansion state upserts per user and is private", %{conn: conn} do
      user = generate(user())
      stranger = generate(user())

      %{"success" => true, "data" => folder} =
        run(conn, user, %{
          "action" => "create_folder",
          "input" => %{"name" => "Archive", "kind" => "conversations"},
          "fields" => ["id"]
        })

      assert %{"success" => true, "data" => %{"isExpanded" => true}} =
               run(conn, user, %{
                 "action" => "upsert_folder_expanded",
                 "input" => %{"folderId" => folder["id"], "isExpanded" => true},
                 "fields" => ["id", "folderId", "isExpanded"]
               })

      # Upsert flips the same row rather than inserting a second one.
      assert %{"success" => true, "data" => %{"isExpanded" => false}} =
               run(conn, user, %{
                 "action" => "upsert_folder_expanded",
                 "input" => %{"folderId" => folder["id"], "isExpanded" => false},
                 "fields" => ["id", "isExpanded"]
               })

      assert %{"success" => true, "data" => [state]} =
               run(conn, user, %{
                 "action" => "my_folder_states",
                 "fields" => ["id", "folderId", "isExpanded"]
               })

      assert state["folderId"] == folder["id"]
      assert state["isExpanded"] == false

      # Strangers cannot attach state to a foreign folder, and see none of it.
      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "upsert_folder_expanded",
                 "input" => %{"folderId" => folder["id"], "isExpanded" => true},
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => []} =
               run(conn, stranger, %{"action" => "my_folder_states", "fields" => ["id"]})
    end
  end

  describe "shell widgets (parity)" do
    test "unread notifications list, mark read, mark all read", %{conn: conn} do
      user = generate(user())
      stranger = generate(user())

      {:ok, first} =
        Magus.Notifications.create_notification(
          %{user_id: user.id, notification_type: :message, title: "Hello"},
          authorize?: false
        )

      {:ok, _second} =
        Magus.Notifications.create_notification(
          %{user_id: user.id, notification_type: :mention},
          authorize?: false
        )

      {:ok, _foreign} =
        Magus.Notifications.create_notification(
          %{user_id: stranger.id, notification_type: :system, title: "Not yours"},
          authorize?: false
        )

      fields = ["id", "title", "notificationType", "targetConversationId", "insertedAt"]

      assert %{"success" => true, "data" => listed} =
               run(conn, user, %{"action" => "unread_notifications", "fields" => fields})

      assert length(listed) == 2
      refute Enum.any?(listed, &(&1["title"] == "Not yours"))

      # Strangers cannot mark another user's notification read.
      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "mark_notification_read",
                 "identity" => first.id,
                 "fields" => ["id"]
               })

      assert %{"success" => true} =
               run(conn, user, %{
                 "action" => "mark_notification_read",
                 "identity" => first.id,
                 "fields" => ["id"]
               })

      assert %{"success" => true, "data" => [_one]} =
               run(conn, user, %{"action" => "unread_notifications", "fields" => ["id"]})

      assert %{"success" => true} =
               run(conn, user, %{"action" => "mark_all_notifications_read"})

      assert %{"success" => true, "data" => []} =
               run(conn, user, %{"action" => "unread_notifications", "fields" => ["id"]})
    end

    test "credit_status returns the actor's usage snapshot", %{conn: conn} do
      user = subscribed_user()

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{"action" => "credit_status"})

      assert is_boolean(data["exempt"])
      assert is_integer(data["credits_used"])
      assert Map.has_key?(data, "credits_limit")
      assert is_number(data["percentage"])
    end

    test "money_usage_status returns the actor's PAYG spend snapshot", %{conn: conn} do
      user = subscribed_user()

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{"action" => "money_usage_status"})

      assert is_boolean(data["exempt"])
      assert is_boolean(data["delinquent"])
      assert is_integer(data["spent_cents"])
      assert is_integer(data["tokens_used"])
      # cap_cents is nil for an uncapped (postpaid opt-out) sub, else an integer.
      assert is_nil(data["cap_cents"]) or is_integer(data["cap_cents"])
    end
  end

  describe "polish batch (companion chat + slash commands)" do
    test "open_companion_chat find-or-creates the linked conversation", %{conn: conn} do
      user = generate(user())

      %{"success" => true, "data" => brain} =
        run(conn, user, %{
          "action" => "create_brain",
          "input" => %{"title" => "Notes"},
          "fields" => ["id"]
        })

      %{"success" => true, "data" => page} =
        run(conn, user, %{
          "action" => "create_brain_page",
          "input" => %{"brainId" => brain["id"], "title" => "Ideas"},
          "fields" => ["id"]
        })

      assert %{"success" => true, "data" => %{"conversation_id" => conversation_id}} =
               run(conn, user, %{
                 "action" => "open_companion_chat",
                 "input" => %{"resourceType" => "brain_page", "resourceId" => page["id"]}
               })

      assert is_binary(conversation_id)

      # Idempotent: the second call returns the same conversation.
      assert %{"success" => true, "data" => %{"conversation_id" => ^conversation_id}} =
               run(conn, user, %{
                 "action" => "open_companion_chat",
                 "input" => %{"resourceType" => "brain_page", "resourceId" => page["id"]}
               })
    end

    test "strangers cannot open a companion chat for another user's page", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())

      %{"success" => true, "data" => brain} =
        run(conn, owner, %{
          "action" => "create_brain",
          "input" => %{"title" => "Private"},
          "fields" => ["id"]
        })

      %{"success" => true, "data" => page} =
        run(conn, owner, %{
          "action" => "create_brain_page",
          "input" => %{"brainId" => brain["id"], "title" => "Secret"},
          "fields" => ["id"]
        })

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "open_companion_chat",
                 "input" => %{"resourceType" => "brain_page", "resourceId" => page["id"]}
               })
    end

    test "merged_slash_commands returns globals, with agent overrides first", %{conn: conn} do
      user = generate(user())

      assert %{"success" => true, "data" => globals} =
               run(conn, user, %{
                 "action" => "merged_slash_commands",
                 "input" => %{"agentId" => nil}
               })

      names = Enum.map(globals, & &1["name"])
      assert "web-search" in names
      assert Enum.all?(globals, &(is_binary(&1["title"]) and &1["title"] != ""))

      %{"success" => true, "data" => agent} =
        run(conn, user, %{
          "action" => "create_custom_agent",
          "input" => %{
            "name" => "Scribe #{System.unique_integer([:positive])}",
            "instructions" => "Write things down.",
            "slashCommands" => [
              %{
                "name" => "web-search",
                "title" => %{"en" => "Custom search"},
                "instruction" => "Use my custom search flow."
              }
            ]
          },
          "fields" => ["id"]
        })

      assert %{"success" => true, "data" => merged} =
               run(conn, user, %{
                 "action" => "merged_slash_commands",
                 "input" => %{"agentId" => agent["id"]}
               })

      override = Enum.find(merged, &(&1["name"] == "web-search"))
      assert override["title"] == "Custom search"
      assert Enum.count(merged, &(&1["name"] == "web-search")) == 1
    end
  end

  describe "message attachments (parity)" do
    test "messages carry attachment ids and files_for_display resolves them", %{conn: conn} do
      user = subscribed_user()
      conversation = generate(conversation(actor: user))
      file = generate(file(actor: user, conversation_id: conversation.id))

      %{"success" => true, "data" => sent} =
        run(conn, user, %{
          "action" => "send_user_message",
          "input" => %{
            "conversationId" => conversation.id,
            "text" => "see attached",
            "resources" => [%{"type" => "file", "id" => file.id}]
          },
          "fields" => ["id", "attachments"]
        })

      assert sent["attachments"] == [file.id]

      assert %{"success" => true, "data" => [display]} =
               run(conn, user, %{
                 "action" => "files_for_display",
                 "input" => %{"ids" => [file.id]}
               })

      assert display["id"] == file.id
      assert is_binary(display["name"])
      assert Map.has_key?(display, "url")
    end

    test "files_for_display silently drops unreadable files", %{conn: conn} do
      user = subscribed_user()
      other = subscribed_user()
      mine = generate(file(actor: user))
      foreign = generate(file(actor: other))

      assert %{"success" => true, "data" => listed} =
               run(conn, user, %{
                 "action" => "files_for_display",
                 "input" => %{"ids" => [mine.id, foreign.id]}
               })

      ids = Enum.map(listed, & &1["id"])
      assert mine.id in ids
      refute foreign.id in ids
    end
  end

  describe "file sharing (parity)" do
    test "share/unshare a workspace file round-trips", %{conn: conn} do
      user = subscribed_user()
      workspace = generate(workspace(actor: user))
      file = generate(file(actor: user, workspace_id: workspace.id))

      assert %{"success" => true, "data" => %{"isSharedToWorkspace" => true}} =
               run(conn, user, %{
                 "action" => "share_file_to_team",
                 "identity" => file.id,
                 "fields" => ["id", "isSharedToWorkspace"]
               })

      assert %{"success" => true, "data" => %{"isSharedToWorkspace" => false}} =
               run(conn, user, %{
                 "action" => "unshare_file_from_team",
                 "identity" => file.id,
                 "fields" => ["id", "isSharedToWorkspace"]
               })
    end

    test "sharing a personal file is rejected", %{conn: conn} do
      user = subscribed_user()
      file = generate(file(actor: user))

      assert %{"success" => false} =
               run(conn, user, %{
                 "action" => "share_file_to_team",
                 "identity" => file.id,
                 "fields" => ["id"]
               })
    end

    test "share/unshare a workspace folder round-trips", %{conn: conn} do
      user = generate(user())
      workspace = generate(workspace(actor: user))

      %{"success" => true, "data" => folder} =
        run(conn, user, %{
          "action" => "create_folder",
          "input" => %{"name" => "Team docs", "kind" => "files", "workspaceId" => workspace.id},
          "fields" => ["id"]
        })

      assert %{"success" => true, "data" => %{"isSharedToWorkspace" => true}} =
               run(conn, user, %{
                 "action" => "share_folder_to_team",
                 "identity" => folder["id"],
                 "fields" => ["id", "isSharedToWorkspace"]
               })

      assert %{"success" => true, "data" => %{"isSharedToWorkspace" => false}} =
               run(conn, user, %{
                 "action" => "unshare_folder_from_team",
                 "identity" => folder["id"],
                 "fields" => ["id", "isSharedToWorkspace"]
               })
    end
  end

  describe "knowledge collections (parity)" do
    defp create_collection(user) do
      {:ok, source} =
        Magus.Knowledge.create_source(
          %{name: "Test source", provider: :notion, auth_config: %{"key" => "test"}},
          actor: user
        )

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "Docs", external_id: "ext_1", external_path: "/docs"},
          actor: user
        )

      collection
    end

    test "my_knowledge_collections lists only the actor's collections", %{conn: conn} do
      user = generate(user())
      stranger = generate(user())
      collection = create_collection(user)

      assert %{"success" => true, "data" => listed} =
               run(conn, user, %{
                 "action" => "my_knowledge_collections",
                 "fields" => ["id", "name", "syncStatus", "itemCount"]
               })

      assert Enum.any?(listed, &(&1["id"] == collection.id))

      assert %{"success" => true, "data" => stranger_listed} =
               run(conn, stranger, %{
                 "action" => "my_knowledge_collections",
                 "fields" => ["id"]
               })

      refute Enum.any?(stranger_listed, &(&1["id"] == collection.id))
    end

    test "collection_files lists the collection's synced files", %{conn: conn} do
      user = subscribed_user()
      collection = create_collection(user)

      assert %{"success" => true, "data" => []} =
               run(conn, user, %{
                 "action" => "collection_files",
                 "input" => %{"knowledgeCollectionId" => collection.id},
                 "fields" => ["id", "name"]
               })
    end
  end

  describe "draft editing (magus-3as)" do
    test "update_draft_content writes PM JSON and bumps the version", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, draft} =
        Magus.Drafts.create_draft(conversation.id, "Notes", "Hello", user.id, actor: user)

      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "text" => "Edited in the SPA"}]
          }
        ]
      }

      assert %{"success" => true, "data" => updated} =
               run(conn, user, %{
                 "action" => "update_draft_content",
                 "identity" => draft.id,
                 "input" => %{"contentJson" => doc},
                 "fields" => ["id", "version", "content"]
               })

      assert updated["version"] == draft.version + 1
      assert updated["content"]["type"] == "doc"

      assert %{"success" => true, "data" => %{"title" => "Renamed"}} =
               run(conn, user, %{
                 "action" => "rename_draft",
                 "identity" => draft.id,
                 "input" => %{"title" => "Renamed"},
                 "fields" => ["id", "title"]
               })
    end

    test "strangers cannot edit another user's draft", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))

      {:ok, draft} =
        Magus.Drafts.create_draft(conversation.id, "Private", "Body", owner.id, actor: owner)

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "update_draft_content",
                 "identity" => draft.id,
                 "input" => %{"contentJson" => %{"type" => "doc", "content" => []}},
                 "fields" => ["id"]
               })
    end

    test "invalid documents are rejected", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, draft} =
        Magus.Drafts.create_draft(conversation.id, "Notes", "Hello", user.id, actor: user)

      assert %{"success" => false} =
               run(conn, user, %{
                 "action" => "update_draft_content",
                 "identity" => draft.id,
                 "input" => %{"contentJson" => %{"not" => "a doc"}},
                 "fields" => ["id"]
               })
    end
  end

  describe "brain version history (magus-oni)" do
    test "version diff, body, and restore round-trip", %{conn: conn} do
      user = generate(user())

      %{"success" => true, "data" => brain} =
        run(conn, user, %{
          "action" => "create_brain",
          "input" => %{"title" => "Journal"},
          "fields" => ["id"]
        })

      %{"success" => true, "data" => page} =
        run(conn, user, %{
          "action" => "create_brain_page",
          "input" => %{"brainId" => brain["id"], "title" => "Log"},
          "fields" => ["id", "lockVersion"]
        })

      %{"success" => true, "data" => first_save} =
        run(conn, user, %{
          "action" => "update_brain_page_body",
          "identity" => page["id"],
          "input" => %{"body" => "first version", "baseVersion" => page["lockVersion"]},
          "fields" => ["id", "lockVersion"]
        })

      %{"success" => true} =
        run(conn, user, %{
          "action" => "update_brain_page_body",
          "identity" => page["id"],
          "input" => %{"body" => "second version", "baseVersion" => first_save["lockVersion"]},
          "fields" => ["id", "lockVersion"]
        })

      %{"success" => true, "data" => versions} =
        run(conn, user, %{
          "action" => "list_brain_page_versions",
          "input" => %{"pageId" => page["id"]}
        })

      body_versions = Enum.filter(versions, &(&1["action_name"] == "update_body"))
      assert length(body_versions) == 2
      [latest, previous] = body_versions

      assert %{"success" => true, "data" => diff} =
               run(conn, user, %{
                 "action" => "brain_page_version_diff",
                 "input" => %{"pageId" => page["id"], "versionId" => latest["version_id"]}
               })

      assert diff["is_latest"] == true
      assert Enum.any?(diff["rows"], &(&1["kind"] in ["del", "ins"]))

      assert %{"success" => true, "data" => "first version"} =
               run(conn, user, %{
                 "action" => "brain_page_version_body",
                 "input" => %{"pageId" => page["id"], "versionId" => previous["version_id"]}
               })
    end

    test "strangers cannot read version history", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())

      %{"success" => true, "data" => brain} =
        run(conn, owner, %{
          "action" => "create_brain",
          "input" => %{"title" => "Private"},
          "fields" => ["id"]
        })

      %{"success" => true, "data" => page} =
        run(conn, owner, %{
          "action" => "create_brain_page",
          "input" => %{"brainId" => brain["id"], "title" => "Secret"},
          "fields" => ["id"]
        })

      assert %{"success" => false} =
               run(conn, stranger, %{
                 "action" => "brain_page_version_diff",
                 "input" => %{
                   "pageId" => page["id"],
                   "versionId" => Ash.UUIDv7.generate()
                 }
               })
    end
  end

  describe "agent inspect/edit split (magus-r2e)" do
    test "editable_by_actor reflects update permission", %{conn: conn} do
      owner = generate(user())
      member = generate(user())
      workspace = generate(workspace(actor: owner))
      workspace_member(user_id: member.id, workspace_id: workspace.id)

      %{"success" => true, "data" => agent} =
        run(conn, owner, %{
          "action" => "create_custom_agent",
          "input" => %{
            "name" => "Shared Scribe #{System.unique_integer([:positive])}",
            "instructions" => "Help out.",
            "workspaceId" => workspace.id
          },
          "fields" => ["id"]
        })

      %{"success" => true} =
        run(conn, owner, %{
          "action" => "share_agent_to_team",
          "identity" => agent["id"],
          "fields" => ["id"]
        })

      assert %{"success" => true, "data" => %{"editableByActor" => true}} =
               run(conn, owner, %{
                 "action" => "get_custom_agent",
                 "getBy" => %{"id" => agent["id"]},
                 "fields" => ["id", "editableByActor"]
               })

      assert %{"success" => true, "data" => %{"editableByActor" => false}} =
               run(conn, member, %{
                 "action" => "get_custom_agent",
                 "getBy" => %{"id" => agent["id"]},
                 "fields" => ["id", "editableByActor"]
               })
    end
  end

  describe "staged upload cleanup (magus-5cd)" do
    test "owners can hard-delete a never-sent upload; strangers cannot", %{conn: conn} do
      user = subscribed_user()
      stranger = subscribed_user()
      conversation = generate(conversation(actor: user))
      file = generate(file(actor: user, conversation_id: conversation.id))

      # Filter-check policies make a foreign destroy a zero-row no-op; the
      # important property is that the file survives it.
      run(conn, stranger, %{"action" => "delete_file", "identity" => file.id})

      assert %{"success" => true, "data" => %{"id" => _}} =
               run(conn, user, %{
                 "action" => "get_file",
                 "getBy" => %{"id" => file.id},
                 "fields" => ["id"]
               })

      assert %{"success" => true} =
               run(conn, user, %{"action" => "delete_file", "identity" => file.id})

      assert %{"success" => false} =
               run(conn, user, %{
                 "action" => "get_file",
                 "getBy" => %{"id" => file.id},
                 "fields" => ["id"]
               })
    end
  end

  describe "settings — account (magus-tii)" do
    test "update_user_settings changes display name, name, and language", %{conn: conn} do
      user = generate(user(language: :en))
      new_name = "Renamed #{System.unique_integer([:positive])}"

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "update_user_settings",
                 "identity" => user.id,
                 "input" => %{
                   "displayName" => new_name,
                   "name" => "Ada Lovelace",
                   "language" => "de"
                 },
                 "fields" => ["id", "displayName", "name", "language"]
               })

      assert data["displayName"] == new_name
      assert data["name"] == "Ada Lovelace"
      assert data["language"] == "de"
    end

    test "update_user_settings is rejected for another user's id", %{conn: conn} do
      user = generate(user())
      other = generate(user())

      assert %{"success" => false} =
               run(conn, user, %{
                 "action" => "update_user_settings",
                 "identity" => other.id,
                 "input" => %{"displayName" => "Hijacked"},
                 "fields" => ["id"]
               })
    end

    test "select_default_model sets the user's chat model", %{conn: conn} do
      user = generate(user())
      model = generate(model())

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "select_default_model",
                 "identity" => user.id,
                 "input" => %{"selectedModelId" => model.id},
                 "fields" => ["id", "selectedModelId"]
               })

      assert data["selectedModelId"] == model.id
    end

    test "update_timezone stores an IANA zone", %{conn: conn} do
      require Ecto.Query
      user = generate(user())

      # Registration stamps last_timezone_change_at (anti-gaming); clear it so
      # the 30-day rate limit doesn't block this happy-path check.
      Magus.Repo.update_all(
        Ecto.Query.from(u in Magus.Accounts.User, where: u.id == ^user.id),
        set: [last_timezone_change_at: nil]
      )

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "update_timezone",
                 "identity" => user.id,
                 "input" => %{"timezone" => "America/New_York"},
                 "fields" => ["id", "timezone"]
               })

      assert data["timezone"] == "America/New_York"
    end

    test "request_email_change records the pending address", %{conn: conn} do
      user = generate(user())
      new_email = "pending-#{System.unique_integer([:positive])}@test.com"

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "request_email_change",
                 "identity" => user.id,
                 "input" => %{"newEmail" => new_email},
                 "fields" => ["id", "pendingEmail"]
               })

      assert data["pendingEmail"] == new_email
    end

    test "change_user_password updates the password with the current one", %{conn: conn} do
      user = generate(user(password: "Password123!"))

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "change_user_password",
                 "identity" => user.id,
                 "input" => %{
                   "currentPassword" => "Password123!",
                   "password" => "NewPassword456!",
                   "passwordConfirmation" => "NewPassword456!"
                 },
                 "fields" => ["id", "hasPassword"]
               })

      assert data["hasPassword"] == true
    end

    test "current_user exposes the settings projection including hasPassword", %{conn: conn} do
      user = generate(user())

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "current_user",
                 "fields" => ["id", "email", "hasPassword", "timezone", "pendingEmail"]
               })

      assert data["id"] == user.id
      assert data["hasPassword"] == true
    end

    test "list_image_generation_models filters by output modality", %{conn: conn} do
      user = generate(user())
      image_model = generate(model(output_modalities: ["image"]))
      text_model = generate(model(output_modalities: ["text"]))

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "list_image_generation_models",
                 "fields" => ["id", "name"]
               })

      ids = Enum.map(data, & &1["id"])
      assert image_model.id in ids
      refute text_model.id in ids
    end

    test "list_video_generation_models filters by output modality", %{conn: conn} do
      user = generate(user())
      video_model = generate(model(output_modalities: ["video"]))
      text_model = generate(model(output_modalities: ["text"]))

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "list_video_generation_models",
                 "fields" => ["id", "name"]
               })

      ids = Enum.map(data, & &1["id"])
      assert video_model.id in ids
      refute text_model.id in ids
    end
  end

  describe "jobs route (magus-1e2)" do
    test "user_jobs returns the actor's jobs across conversations", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))
      job = job(conversation_id: conversation.id, user_id: user.id, name: "Daily digest")

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "user_jobs",
                 "input" => %{"userId" => user.id},
                 "fields" => ["id", "name", "status", "triggerPrompt", "conversationId"]
               })

      entry = Enum.find(data, &(&1["id"] == job.id))
      assert entry["name"] == "Daily digest"
      assert entry["conversationId"] == conversation.id
      assert entry["triggerPrompt"]
    end

    test "user_jobs does not leak another user's jobs", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))
      job = job(conversation_id: conversation.id, user_id: owner.id)

      # The actor scope filters even when another user's id is supplied.
      assert %{"success" => true, "data" => data} =
               run(conn, stranger, %{
                 "action" => "user_jobs",
                 "input" => %{"userId" => owner.id},
                 "fields" => ["id"]
               })

      refute Enum.any?(data, &(&1["id"] == job.id))
    end

    test "job_runs returns run history for the actor's job", %{conn: conn} do
      user = generate(user())
      conversation = generate(conversation(actor: user))
      job = job(conversation_id: conversation.id, user_id: user.id)
      run_record = generate(job_run(job_id: job.id))

      assert %{"success" => true, "data" => data} =
               run(conn, user, %{
                 "action" => "job_runs",
                 "input" => %{"jobId" => job.id},
                 "fields" => ["id", "status", "startedAt"]
               })

      assert Enum.any?(data, &(&1["id"] == run_record.id))
    end

    test "job_runs is empty for a stranger (owner-gated)", %{conn: conn} do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))
      job = job(conversation_id: conversation.id, user_id: owner.id)
      generate(job_run(job_id: job.id))

      assert %{"success" => true, "data" => data} =
               run(conn, stranger, %{
                 "action" => "job_runs",
                 "input" => %{"jobId" => job.id},
                 "fields" => ["id"]
               })

      assert data == []
    end
  end
end
