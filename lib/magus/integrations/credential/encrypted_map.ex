defmodule Magus.Integrations.EncryptedMap do
  @moduledoc """
  Ash type for storing encrypted maps using Cloak.

  Used by the Credential resource to store sensitive data like
  API keys, OAuth tokens, and IMAP passwords.

  Data is encrypted at rest using AES-256-GCM via Cloak.
  """

  use Ash.Type

  @impl Ash.Type
  def storage_type(_), do: :binary

  @impl Ash.Type
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, _) when is_map(value) do
    {:ok, value}
  end

  def cast_input(value, _) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  def cast_input(_, _), do: :error

  @impl Ash.Type
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(value, _) when is_binary(value) do
    case Magus.Integrations.Vault.decrypt(value) do
      {:ok, decrypted} ->
        case Jason.decode(decrypted) do
          {:ok, map} -> {:ok, map}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def cast_stored(_, _), do: :error

  @impl Ash.Type
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(value, _) when is_map(value) do
    case Jason.encode(value) do
      {:ok, json} ->
        {:ok, Magus.Integrations.Vault.encrypt!(json)}

      _ ->
        :error
    end
  end

  def dump_to_native(_, _), do: :error
end
