defmodule Magus.Agents.Persistence.CheckpointTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Persistence.Checkpoint, as: Persistence

  describe "get_value/2" do
    test "returns value for atom key" do
      assert Persistence.get_value(%{user_id: "123"}, :user_id) == "123"
    end

    test "returns value for string key when atom key missing" do
      assert Persistence.get_value(%{"user_id" => "123"}, :user_id) == "123"
    end

    test "prefers atom key over string key" do
      map = %{"user_id" => "string"} |> Map.put(:user_id, "atom")
      assert Persistence.get_value(map, :user_id) == "atom"
    end

    test "returns nil when key is missing" do
      assert Persistence.get_value(%{other: "value"}, :user_id) == nil
    end

    test "returns nil for non-map input" do
      assert Persistence.get_value(nil, :user_id) == nil
      assert Persistence.get_value("string", :user_id) == nil
    end
  end

  describe "wrap_checkpoint/3" do
    test "builds canonical checkpoint envelope" do
      assert {:ok, checkpoint} =
               Persistence.wrap_checkpoint(MyAgent, "agent:123", %{user_id: "u1"})

      assert checkpoint == %{
               version: 1,
               agent_module: MyAgent,
               id: "agent:123",
               state: %{user_id: "u1"},
               thread: nil
             }
    end
  end

  describe "extract_state/1" do
    test "extracts nested state from canonical format" do
      data = %{version: 1, id: "a1", state: %{user_id: "u1"}}
      assert Persistence.extract_state(data) == %{user_id: "u1"}
    end

    test "extracts nested state with string keys" do
      data = %{"version" => 1, "id" => "a1", "state" => %{"user_id" => "u1"}}
      assert Persistence.extract_state(data) == %{"user_id" => "u1"}
    end

    test "falls back to top-level for legacy flat format" do
      data = %{id: "a1", user_id: "u1", conversation_id: "c1"}
      assert Persistence.extract_state(data) == data
    end

    test "falls back to top-level when state is nil" do
      data = %{id: "a1", state: nil, user_id: "u1"}
      assert Persistence.extract_state(data) == data
    end

    test "falls back to top-level when state is empty map" do
      data = %{id: "a1", state: %{}, user_id: "u1"}
      assert Persistence.extract_state(data) == data
    end
  end

  describe "validate_required/3" do
    test "returns :ok when all required fields present" do
      data = %{id: "a1"}
      state = %{user_id: "u1", conversation_id: "c1"}

      assert :ok =
               Persistence.validate_required(data, state,
                 data: :id,
                 state: :user_id,
                 state: :conversation_id
               )
    end

    test "returns :ok with string keys" do
      data = %{"id" => "a1"}
      state = %{"user_id" => "u1"}

      assert :ok = Persistence.validate_required(data, state, data: :id, state: :user_id)
    end

    test "returns error for missing data field" do
      data = %{}
      state = %{user_id: "u1"}

      assert {:error, {:missing_field, :id}} =
               Persistence.validate_required(data, state, data: :id, state: :user_id)
    end

    test "returns error for missing state field" do
      data = %{id: "a1"}
      state = %{}

      assert {:error, {:missing_field, :user_id}} =
               Persistence.validate_required(data, state, data: :id, state: :user_id)
    end

    test "returns error for empty string value" do
      data = %{id: ""}
      state = %{user_id: "u1"}

      assert {:error, {:missing_field, :id}} =
               Persistence.validate_required(data, state, data: :id, state: :user_id)
    end

    test "returns first missing field in order" do
      data = %{}
      state = %{}

      assert {:error, {:missing_field, :id}} =
               Persistence.validate_required(data, state,
                 data: :id,
                 state: :user_id,
                 state: :conversation_id
               )
    end
  end

  describe "parse_datetime/1" do
    test "returns nil for nil" do
      assert Persistence.parse_datetime(nil) == nil
    end

    test "passes through DateTime structs" do
      dt = ~U[2026-01-15 10:30:00Z]
      assert Persistence.parse_datetime(dt) == dt
    end

    test "parses ISO 8601 strings" do
      assert %DateTime{year: 2026, month: 1, day: 15} =
               Persistence.parse_datetime("2026-01-15T10:30:00Z")
    end

    test "returns nil for invalid strings" do
      assert Persistence.parse_datetime("not a date") == nil
    end

    test "returns nil for other types" do
      assert Persistence.parse_datetime(12345) == nil
      assert Persistence.parse_datetime(%{}) == nil
    end
  end
end
