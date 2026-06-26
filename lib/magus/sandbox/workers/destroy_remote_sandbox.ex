defmodule Magus.Sandbox.Workers.DestroyRemoteSandbox do
  @moduledoc """
  Destroys a remote sandbox sprite via the provider API, out of band.

  Enqueued from conversation/sandbox deletion (see
  `Magus.Chat.Conversation.Changes.DeleteFullConversation`) so the deletion
  transaction commits without holding open remote HTTP calls. Oban provides
  durable, backed-off retries in place of the previous in-transaction
  `Process.sleep/1` retry loop (magus-2621). The sprite id is captured at
  enqueue time because the sandbox row is gone (CASCADE) by the time this runs.
  """
  use Oban.Worker, queue: :sandbox_maintenance, max_attempts: 5

  require Logger

  alias Magus.Sandbox.Provider

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    %{"provider" => provider, "sprite_id" => sprite_id} = args
    sandbox_id = Map.get(args, "sandbox_id")
    client = Provider.client_for(%{provider: provider_atom(provider)})

    case apply(client, :destroy, [sprite_id]) do
      :ok ->
        Logger.debug("Destroyed #{provider} sprite #{sprite_id} (sandbox #{sandbox_id})")
        :ok

      {:error, :not_found} ->
        Logger.debug("#{provider} sprite #{sprite_id} already gone (sandbox #{sandbox_id})")
        :ok

      {:error, :not_configured} ->
        Logger.debug("#{provider} not configured; skipping sprite #{sprite_id}")
        :ok

      {:error, reason} ->
        if attempt >= max_attempts do
          Logger.error(
            "ORPHANED: failed to destroy #{provider} sprite #{sprite_id} (sandbox " <>
              "#{sandbox_id}) after #{attempt} attempts: #{inspect(reason)}. " <>
              "Must be reconciled manually."
          )
        end

        {:error, reason}
    end
  end

  defp provider_atom(provider) when is_atom(provider), do: provider

  defp provider_atom(provider) when is_binary(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> :unknown
  end
end
