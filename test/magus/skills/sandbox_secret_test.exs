defmodule Magus.Skills.SandboxSecretTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  require Ash.Query

  test "stores an encrypted value and returns only declared keys", %{} do
    user = generate(user())

    {:ok, _} =
      Magus.Skills.create_sandbox_secret(%{key: "DEEPL_API_KEY", value: "secret-1"}, actor: user)

    {:ok, _} =
      Magus.Skills.create_sandbox_secret(%{key: "OTHER_KEY", value: "secret-2"}, actor: user)

    env = Magus.Skills.sandbox_env_for_user(user.id, ["DEEPL_API_KEY", "MISSING_KEY"])

    assert env == %{"DEEPL_API_KEY" => "secret-1"}
    refute Map.has_key?(env, "OTHER_KEY")
    refute Map.has_key?(env, "MISSING_KEY")
  end

  test "another user's secrets are not visible", %{} do
    owner = generate(user())
    other = generate(user())
    {:ok, _} = Magus.Skills.create_sandbox_secret(%{key: "K", value: "v"}, actor: owner)

    assert Magus.Skills.sandbox_env_for_user(other.id, ["K"]) == %{}
  end

  test "value is stored encrypted at rest (ciphertext, not plaintext)", %{} do
    user = generate(user())

    {:ok, _} =
      Magus.Skills.create_sandbox_secret(%{key: "TOKEN", value: "plaintext-value"}, actor: user)

    [%{value: raw}] =
      Magus.Repo.query!("SELECT value FROM sandbox_secrets WHERE user_id = $1", [
        Ecto.UUID.dump!(user.id)
      ]).rows
      |> Enum.map(fn [v] -> %{value: v} end)

    refute raw == "plaintext-value"
    refute String.contains?(to_string(raw), "plaintext-value")
  end

  test "a user's sandbox secrets are deleted when the user is deleted", %{} do
    user = generate(user())
    {:ok, _} = Magus.Skills.create_sandbox_secret(%{key: "K", value: "v"}, actor: user)

    before =
      Magus.Skills.SandboxSecret
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read!(authorize?: false)

    assert length(before) == 1

    # Mirror the account-deletion flow: the User row is dropped directly via
    # Ecto (User has no :destroy action). The user FK must cascade.
    Magus.Repo.delete!(user)

    after_rows =
      Magus.Skills.SandboxSecret
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read!(authorize?: false)

    assert after_rows == []
  end
end
