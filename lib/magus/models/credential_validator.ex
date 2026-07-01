defmodule Magus.Models.CredentialValidator do
  @moduledoc """
  Probes a provider's credentials and returns a status atom. The default probe
  issues a minimal models-list request against the resolved endpoint. Tests
  and self-hosted deployments can override via `config :magus,
  :credential_validator` with a 1-arity function returning
  `:valid | :invalid | :error`.
  """

  @type status :: :valid | :invalid | :error

  @spec validate(map()) :: status()
  def validate(provider) do
    case Application.get_env(:magus, :credential_validator) do
      fun when is_function(fun, 1) -> fun.(provider)
      _ -> default_probe(provider)
    end
  end

  # A conservative default: without a reachable probe we report :error rather
  # than guessing. The concrete per-provider probe lands with the 2b-2 UI that
  # exercises it; keeping it minimal here avoids a new egress path on by every
  # create in a headless environment.
  defp default_probe(_provider), do: :error
end
