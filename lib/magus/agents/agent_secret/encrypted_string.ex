defmodule Magus.Agents.AgentSecret.EncryptedString do
  @moduledoc """
  Ash type for storing encrypted strings using Cloak.

  Used by the AgentSecret resource to store sensitive values like
  API keys and access tokens.

  Data is encrypted at rest using AES-256-GCM via Cloak.
  """

  use Ash.Type

  @impl Ash.Type
  def storage_type(_), do: :binary

  @impl Ash.Type
  def cast_input(nil, _), do: {:ok, nil}
  def cast_input(value, _) when is_binary(value), do: {:ok, value}
  def cast_input(_, _), do: :error

  @impl Ash.Type
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(value, _) when is_binary(value) do
    case Magus.Integrations.Vault.decrypt(value) do
      {:ok, decrypted} -> {:ok, decrypted}
      _ -> :error
    end
  end

  def cast_stored(_, _), do: :error

  @impl Ash.Type
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(value, _) when is_binary(value) do
    {:ok, Magus.Integrations.Vault.encrypt!(value)}
  end

  def dump_to_native(_, _), do: :error
end
