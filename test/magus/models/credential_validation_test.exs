defmodule Magus.Models.CredentialValidationTest do
  use Magus.DataCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Magus.Generators

  setup do
    Magus.DataCase.clear_catalog!()
    user = generate(user())
    %{user: user}
  end

  test "create_owned enqueues a unique validation job", %{user: user} do
    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    assert_enqueued(
      worker: Magus.Models.Workers.ValidateCredential,
      args: %{"provider_id" => provider.id}
    )
  end

  test "worker stamps valid status via the configured validator", %{user: user} do
    Application.put_env(:magus, :credential_validator, fn _provider -> :valid end)
    on_exit(fn -> Application.delete_env(:magus, :credential_validator) end)

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    assert :ok =
             perform_job(Magus.Models.Workers.ValidateCredential, %{"provider_id" => provider.id})

    {:ok, reloaded} = Ash.get(Magus.Models.Provider, provider.id, authorize?: false)
    assert reloaded.validation_status == :valid
    assert reloaded.last_validated_at
  end
end
