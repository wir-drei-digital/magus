defmodule Magus.Integrations.Vault do
  @moduledoc """
  Cloak Vault for encrypting integration credentials.

  Uses AES-256-GCM encryption. The encryption key must be set
  via the INTEGRATION_ENCRYPTION_KEY environment variable as
  a base64-encoded 32-byte key.

  Generate a key with:
    :crypto.strong_rand_bytes(32) |> Base.encode64()
  """

  use Cloak.Vault, otp_app: :magus

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers,
        default: {
          Cloak.Ciphers.AES.GCM,
          tag: "AES.GCM.V1", key: encryption_key!(), iv_length: 12
        }
      )

    {:ok, config}
  end

  # Dev/prod read INTEGRATION_ENCRYPTION_KEY from the environment. The test env
  # sets a deterministic key via `config :magus, Magus.Integrations.Vault, key:`
  # so the suite boots and encrypts with no secrets (fork PRs, fresh checkouts).
  defp encryption_key! do
    configured = Application.get_env(:magus, __MODULE__, [])[:key]

    case configured || System.get_env("INTEGRATION_ENCRYPTION_KEY") do
      nil ->
        raise """
        INTEGRATION_ENCRYPTION_KEY is not set.
        Generate a base64 32-byte key: :crypto.strong_rand_bytes(32) |> Base.encode64()
        """

      value ->
        Base.decode64!(value)
    end
  end
end
