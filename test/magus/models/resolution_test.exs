defmodule Magus.Models.ResolutionTest do
  use ExUnit.Case, async: true

  alias Magus.Models.Resolution

  defp model(attrs), do: struct(Magus.Chat.Model, attrs)

  test "defaults carry the admin-only ownership/billing constants" do
    res = %Resolution{model: model(id: "m1", key: "k"), selection_source: :explicit}

    assert res.access_source == :global
    assert res.credential_owner_user_id == nil
    assert res.cost_source == :platform_key
    assert res.requested_selection == nil
    assert res.provider_id == nil
  end

  test "degraded?/1 is false when nothing explicit was requested" do
    res = %Resolution{model: model(id: "m1", key: "k"), selection_source: :role_default}
    refute Resolution.degraded?(res)
  end

  test "degraded?/1 is false when the requested id matches the model" do
    res = %Resolution{
      model: model(id: "m1", key: "k"),
      selection_source: :explicit,
      requested_selection: %{by: :id, value: "m1"}
    }

    refute Resolution.degraded?(res)
  end

  test "degraded?/1 is true when the requested id does not match the model" do
    res = %Resolution{
      model: model(id: "other", key: "k"),
      selection_source: :explicit,
      requested_selection: %{by: :id, value: "m1"}
    }

    assert Resolution.degraded?(res)
  end

  test "degraded?/1 is true when the requested key does not match the model" do
    res = %Resolution{
      model: model(id: "m1", key: "fallback"),
      selection_source: :product_default,
      requested_selection: %{by: :key, value: "wanted"}
    }

    assert Resolution.degraded?(res)
  end
end
