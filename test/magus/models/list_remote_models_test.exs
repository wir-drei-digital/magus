defmodule Magus.Models.ListRemoteModelsTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  setup do
    Magus.DataCase.clear_catalog!()
    user = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    Application.put_env(:magus, :credential_validator, fn _ -> :valid end)
    Application.put_env(:magus, :credential_probe, fn _ -> {:valid, ["gpt-4o"]} end)

    on_exit(fn ->
      Application.delete_env(:magus, :credential_validator)
      Application.delete_env(:magus, :credential_probe)
    end)

    %{user: user, provider: provider}
  end

  test "owner lists remote models", %{user: user, provider: provider} do
    assert {:ok, %{status: :ok, model_ids: ["gpt-4o"]}} =
             Magus.Models.list_remote_models(provider.id, actor: user)
  end

  test "non-owner is refused", %{provider: provider} do
    other = generate(user())
    assert {:error, _} = Magus.Models.list_remote_models(provider.id, actor: other)
  end

  test "second call inside the window is rate_limited", %{user: user, provider: provider} do
    assert {:ok, %{status: :ok}} = Magus.Models.list_remote_models(provider.id, actor: user)

    assert {:ok, %{status: :rate_limited, model_ids: []}} =
             Magus.Models.list_remote_models(provider.id, actor: user)
  end
end
