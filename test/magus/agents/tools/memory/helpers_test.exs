defmodule Magus.Agents.Tools.Memory.HelpersTest do
  @moduledoc """
  Tests for the shared memory tools helper functions.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Memory.Helpers
  alias Magus.Chat

  describe "get_context_value/2" do
    test "returns value for atom key" do
      context = %{user_id: "123", conversation_id: "456"}
      assert Helpers.get_context_value(context, :user_id) == "123"
      assert Helpers.get_context_value(context, :conversation_id) == "456"
    end

    test "returns value for string key" do
      context = %{"user_id" => "123", "conversation_id" => "456"}
      assert Helpers.get_context_value(context, :user_id) == "123"
      assert Helpers.get_context_value(context, :conversation_id) == "456"
    end

    test "returns nil for missing key" do
      context = %{user_id: "123"}
      assert Helpers.get_context_value(context, :conversation_id) == nil
    end

    test "returns nil for non-map context" do
      assert Helpers.get_context_value(nil, :user_id) == nil
      assert Helpers.get_context_value("not a map", :user_id) == nil
    end

    test "prefers atom key over string key" do
      # Elixir maps can have both atom and string keys for the same "name"
      context = Map.put(%{user_id: "atom_value"}, "user_id", "string_value")
      assert Helpers.get_context_value(context, :user_id) == "atom_value"
    end
  end

  describe "extract_error_message/1" do
    test "extracts messages from Ash.Error.Invalid" do
      error = %Ash.Error.Invalid{
        errors: [
          %{message: "is required"},
          %{message: "must be unique"}
        ]
      }

      assert Helpers.extract_error_message(error) == "is required; must be unique"
    end

    test "handles single error" do
      error = %Ash.Error.Invalid{
        errors: [%{message: "is invalid"}]
      }

      assert Helpers.extract_error_message(error) == "is invalid"
    end

    test "handles empty errors" do
      error = %Ash.Error.Invalid{errors: []}
      assert Helpers.extract_error_message(error) == ""
    end

    test "inspects non-Ash errors" do
      assert Helpers.extract_error_message(:some_error) == ":some_error"
      assert Helpers.extract_error_message("string error") == "\"string error\""
    end
  end

  describe "format_datetime/1" do
    test "formats datetime correctly" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-03-15T14:30:00Z")
      assert Helpers.format_datetime(dt) == "2024-03-15 14:30"
    end

    test "returns nil for nil input" do
      assert Helpers.format_datetime(nil) == nil
    end
  end

  describe "ai_actor/0" do
    test "returns AiAgent struct" do
      assert %Magus.Agents.Support.AiAgent{} = Helpers.ai_actor()
    end
  end

  describe "enforce_global_read_isolation/2" do
    test "passes through when can_read_global_memories is true" do
      context = %{can_read_global_memories: true}
      assert {:ok, "user"} = Helpers.enforce_global_read_isolation("user", context)
      assert {:ok, "all"} = Helpers.enforce_global_read_isolation("all", context)
      assert {:ok, "local"} = Helpers.enforce_global_read_isolation("local", context)
    end

    test "blocks global scope when can_read_global_memories is false" do
      context = %{can_read_global_memories: false}
      assert {:error, msg} = Helpers.enforce_global_read_isolation("user", context)
      assert msg =~ "cannot access global memories"
      assert msg =~ "Use scope 'local' instead"
    end

    test "downgrades 'all' to 'local' when can_read_global_memories is false" do
      context = %{can_read_global_memories: false}
      assert {:ok, "local"} = Helpers.enforce_global_read_isolation("all", context)
    end

    test "allows local scope when can_read_global_memories is false" do
      context = %{can_read_global_memories: false}
      assert {:ok, "local"} = Helpers.enforce_global_read_isolation("local", context)
    end

    test "defaults to allowed when flag is missing from context" do
      assert {:ok, "user"} = Helpers.enforce_global_read_isolation("user", %{})
    end
  end

  describe "enforce_global_write_isolation/2" do
    test "passes through when can_write_global_memories is true" do
      context = %{can_write_global_memories: true}
      assert {:ok, "user"} = Helpers.enforce_global_write_isolation("user", context)
      assert {:ok, "local"} = Helpers.enforce_global_write_isolation("local", context)
    end

    test "blocks global scope when can_write_global_memories is false" do
      context = %{can_write_global_memories: false}
      assert {:error, msg} = Helpers.enforce_global_write_isolation("user", context)
      assert msg =~ "cannot create or modify global memories"
      assert msg =~ "Use scope 'local' instead"
    end

    test "allows local scope when can_write_global_memories is false" do
      context = %{can_write_global_memories: false}
      assert {:ok, "local"} = Helpers.enforce_global_write_isolation("local", context)
    end

    test "defaults to allowed when flag is missing from context" do
      assert {:ok, "user"} = Helpers.enforce_global_write_isolation("user", %{})
    end
  end

  describe "validate_context/2" do
    test "returns ok with extracted values when all keys present" do
      context = %{user_id: "123", conversation_id: "456", folder_id: "789"}

      assert {:ok, extracted} = Helpers.validate_context(context, [:user_id, :conversation_id])
      assert extracted.user_id == "123"
      assert extracted.conversation_id == "456"
    end

    test "returns error when keys are missing" do
      context = %{user_id: "123"}

      assert {:error, message} = Helpers.validate_context(context, [:user_id, :conversation_id])
      assert message =~ "Missing required context"
      assert message =~ "conversation_id"
    end

    test "returns error listing all missing keys" do
      context = %{}

      assert {:error, message} =
               Helpers.validate_context(context, [:user_id, :conversation_id])

      assert message =~ "user_id"
      assert message =~ "conversation_id"
    end

    test "works with string keys in context" do
      context = %{"user_id" => "123", "conversation_id" => "456"}

      assert {:ok, extracted} = Helpers.validate_context(context, [:user_id, :conversation_id])
      assert extracted.user_id == "123"
      assert extracted.conversation_id == "456"
    end
  end

  describe "resolve_user_bucket/1" do
    test "derives the bucket from a workspace conversation" do
      user = generate(user())
      workspace = generate(workspace(actor: user))
      {:ok, conv} = Chat.create_conversation(%{workspace_id: workspace.id}, actor: user)

      assert {:ok, ws} = Helpers.resolve_user_bucket(%{conversation_id: conv.id})
      assert ws == workspace.id
    end

    test "derives nil (personal) from a personal conversation" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)

      assert {:ok, nil} = Helpers.resolve_user_bucket(%{conversation_id: conv.id})
    end

    test "conversation takes precedence over a stale ctx workspace_id" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)

      assert {:ok, nil} =
               Helpers.resolve_user_bucket(%{
                 conversation_id: conv.id,
                 workspace_id: Ash.UUID.generate()
               })
    end

    test "invalid conversation id is an error, never a silent personal write" do
      assert {:error, :conversation_not_found} =
               Helpers.resolve_user_bucket(%{conversation_id: Ash.UUID.generate()})
    end

    test "falls back to an explicitly present workspace_id key" do
      ws = Ash.UUID.generate()
      assert {:ok, ^ws} = Helpers.resolve_user_bucket(%{workspace_id: ws})
    end

    test "a present nil workspace_id is an explicit personal choice" do
      assert {:ok, nil} = Helpers.resolve_user_bucket(%{workspace_id: nil})
    end

    test "string keys work" do
      ws = Ash.UUID.generate()
      assert {:ok, ^ws} = Helpers.resolve_user_bucket(%{"workspace_id" => ws})
    end

    test "no bucket context at all is an error" do
      assert {:error, :no_bucket_context} = Helpers.resolve_user_bucket(%{user_id: "x"})
    end
  end
end
