defmodule Magus.Agents.Tools.HelpersTest do
  @moduledoc """
  Tests for the shared tools helper functions.
  """
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Helpers

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
      context = Map.put(%{user_id: "atom_value"}, "user_id", "string_value")
      assert Helpers.get_context_value(context, :user_id) == "atom_value"
    end
  end

  describe "get_int_param/3" do
    test "returns an integer value as-is" do
      assert Helpers.get_int_param(%{limit: 5}, :limit, 20) == 5
    end

    test "coerces a numeric string (LLMs often send \"10\")" do
      assert Helpers.get_int_param(%{"limit" => "10"}, :limit, 20) == 10
      assert Helpers.get_int_param(%{limit: " 7 "}, :limit, 20) == 7
    end

    test "truncates a float (LLMs sometimes send 10.0)" do
      assert Helpers.get_int_param(%{limit: 10.9}, :limit, 20) == 10
    end

    test "falls back to the default for nil / missing" do
      assert Helpers.get_int_param(%{}, :limit, 20) == 20
      assert Helpers.get_int_param(%{limit: nil}, :limit, 20) == 20
    end

    test "falls back to the default for an unparseable string" do
      assert Helpers.get_int_param(%{limit: "lots"}, :limit, 20) == 20
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

    test "handles Ash.Error.Forbidden" do
      error = %Ash.Error.Forbidden{
        errors: [%{message: "not authorized"}]
      }

      assert Helpers.extract_error_message(error) =~ "Authorization failed"
      assert Helpers.extract_error_message(error) =~ "not authorized"
    end

    test "handles NotFound errors" do
      error = %Ash.Error.Invalid{
        errors: [%Ash.Error.Query.NotFound{resource: Magus.Workflows.Job}]
      }

      result = Helpers.extract_error_message(error)
      assert result =~ "Magus.Workflows.Job"
      assert result =~ "not found"
    end

    test "InvalidAttribute errors include the offending field name" do
      error = %Ash.Error.Invalid{
        errors: [
          %Ash.Error.Changes.InvalidAttribute{field: :content, message: "is invalid"}
        ]
      }

      assert Helpers.extract_error_message(error) == "content: is invalid"
    end

    test "inspects non-Ash errors" do
      assert Helpers.extract_error_message(:some_error) == ":some_error"
      assert Helpers.extract_error_message("string error") == "\"string error\""
    end
  end

  describe "ai_actor/0" do
    test "returns AiAgent struct" do
      assert %Magus.Agents.Support.AiAgent{} = Helpers.ai_actor()
    end
  end

  describe "tool_error/3" do
    test "formats an Ash.Error.Invalid with a recovery hint" do
      err = %Ash.Error.Invalid{errors: [%{message: "title is required"}]}

      assert Helpers.tool_error("write page", err, "Pass a non-empty title.") ==
               "Failed to write page: title is required. Pass a non-empty title."
    end

    test "omits the hint section when none is provided" do
      err = %Ash.Error.Forbidden{errors: [%{message: "denied"}]}

      assert Helpers.tool_error("delete page", err) ==
               "Failed to delete page: Authorization failed: denied."
    end

    test "still produces a readable message for non-Ash errors" do
      assert Helpers.tool_error("read page", :timeout, "Retry once.") ==
               "Failed to read page: :timeout. Retry once."
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
end
