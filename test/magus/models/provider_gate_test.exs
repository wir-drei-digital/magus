defmodule Magus.Models.ProviderGateTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  defmodule Deny do
    @behaviour Magus.Models.ProviderGate
    def can_create?(_user), do: {:error, :paid_plan_required}
  end

  setup do
    Magus.DataCase.clear_catalog!()
    %{user: generate(user())}
  end

  test "default gate allows create", %{user: user} do
    assert {:ok, _} =
             Magus.Models.create_owned_provider(
               %{name: "P", req_llm_id: "openai", api_key: "sk"},
               actor: user
             )
  end

  test "deny impl blocks create and key update, not name edit", %{user: user} do
    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "P", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    Application.put_env(:magus, :provider_gate, __MODULE__.Deny)
    on_exit(fn -> Application.delete_env(:magus, :provider_gate) end)

    assert {:error, _} =
             Magus.Models.create_owned_provider(
               %{name: "Q", req_llm_id: "openai", api_key: "sk2"},
               actor: user
             )

    assert {:error, _} =
             Magus.Models.update_owned_provider(provider, %{api_key: "sk-new"}, actor: user)

    assert {:ok, _} =
             Magus.Models.update_owned_provider(provider, %{name: "Renamed"}, actor: user)
  end
end
