defmodule Magus.Models.Provider.Actions.ListRemoteModels do
  @moduledoc """
  Generic-action run module for `:list_remote_models`. Loads the provider,
  enforces owner scope in the query (guarded binary actor so a nil actor
  never reaches the pin), rate-windows the live probe, and maps the
  `CredentialValidator.probe/1` result to a status map. No secrets are
  returned or logged.
  """

  use Ash.Resource.Actions.Implementation
  require Ash.Query

  @window_ms 10_000

  @impl true
  def run(input, _opts, %{actor: %{id: actor_id}}) when is_binary(actor_id) do
    provider_id = input.arguments.provider_id

    with {:ok, %{} = provider} <-
           Magus.Models.Provider
           |> Ash.Query.filter(id == ^provider_id and owner_user_id == ^actor_id)
           |> Ash.read_one(authorize?: false),
         true <- Magus.Models.RateWindow.allow?({:remote_models, provider_id}, @window_ms) do
      case Magus.Models.CredentialValidator.probe(provider) do
        {:valid, ids} -> {:ok, %{status: :ok, model_ids: ids}}
        :invalid -> {:ok, %{status: :unauthorized, model_ids: []}}
        :error -> {:ok, %{status: :unavailable, model_ids: []}}
      end
    else
      false -> {:ok, %{status: :rate_limited, model_ids: []}}
      _ -> {:error, "provider not found"}
    end
  end

  def run(_input, _opts, _context), do: {:error, "requires an actor"}
end
