defmodule Magus.Accounts.ApiToken.Secret do
  @moduledoc """
  Pure functions for generating, hashing, and prefixing brain-API
  Personal Access Tokens.

  Plaintext format: `mgs_pat_<32 base62 chars>`. The plaintext is
  shown to the user once at creation; only the SHA-256 hash and the
  first 14 chars (the display prefix) are persisted.
  """

  @prefix "mgs_pat_"
  @random_length 32
  @display_prefix_length 14

  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  @alphabet_size 62

  @doc "Generate a new plaintext PAT."
  @spec generate() :: String.t()
  def generate do
    random =
      :crypto.strong_rand_bytes(@random_length)
      |> :binary.bin_to_list()
      |> Enum.map(fn byte -> Enum.at(@alphabet, rem(byte, @alphabet_size)) end)
      |> List.to_string()

    @prefix <> random
  end

  @doc "Compute the SHA-256 hex digest of a plaintext token."
  @spec hash(String.t()) :: String.t()
  def hash(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  @doc "Return the display prefix (first 14 chars) of a plaintext token."
  @spec prefix(String.t()) :: String.t()
  def prefix(token) when is_binary(token) do
    String.slice(token, 0, @display_prefix_length)
  end
end
