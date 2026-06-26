defmodule Magus.Models.RolesTest do
  use ExUnit.Case, async: true

  alias Magus.Models.Roles

  test "all/0 returns every role with required fields" do
    roles = Roles.all()
    keys = Enum.map(roles, & &1.key)

    assert :chat_default in keys
    assert :title_generation in keys
    assert :summary in keys
    assert :memory_extraction in keys
    assert :intent_classification in keys
    assert :embeddings in keys
    assert :super_brain_extraction in keys
    assert :image_default in keys
    assert :video_t2v in keys
    assert :video_i2v in keys
    assert :sub_agent_default in keys

    for role <- roles do
      assert is_atom(role.key)
      assert is_binary(role.description)
      assert role.capability in [:chat, :embedding, :image, :video]
      assert is_boolean(role.nilable?)
    end
  end

  test "get!/1 returns a role and raises on unknown" do
    assert %{key: :summary, capability: :chat} = Roles.get!(:summary)
    assert_raise KeyError, fn -> Roles.get!(:nonexistent_role) end
  end

  test "fallback chains terminate and reference real roles" do
    keys = MapSet.new(Roles.all(), & &1.key)

    for role <- Roles.all(), role.fallback != nil do
      assert MapSet.member?(keys, role.fallback), "#{role.key} falls back to unknown role"
    end

    # no cycles: walking any chain ends within the role count
    max_depth = MapSet.size(keys)

    for role <- Roles.all() do
      depth =
        Stream.iterate(role, fn r -> r.fallback && Roles.get!(r.fallback) end)
        |> Stream.take_while(& &1)
        |> Enum.take(max_depth + 1)
        |> length()

      assert depth <= max_depth, "fallback cycle at #{role.key}"
    end
  end

  test "nilable roles have no fallback (disabled means off, not next-in-chain)" do
    for role <- Roles.all(), role.nilable? do
      assert role.fallback == nil
    end
  end
end
