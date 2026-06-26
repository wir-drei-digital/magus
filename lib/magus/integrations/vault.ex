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
          tag: "AES.GCM.V1", key: decode_env!("INTEGRATION_ENCRYPTION_KEY"), iv_length: 12
        }
      )

    {:ok, config}
  end

  defp decode_env!(var) do
    case System.get_env(var) do
      nil ->
        raise """
        Environment variable #{var} is not set.
        Generate one with: elixir -e ":crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()"
        """

      value ->
        Base.decode64!(value)
    end
  end
end
