defmodule Magus.Integrations.Workers.PollDataSource do
  @moduledoc """
  Standalone Oban worker for polling pull-type data source integrations (e.g., RSS feeds).

  Self-re-enqueues after each successful poll at the interval configured in the
  integration's config. Stops re-enqueuing if the integration is deactivated.

  ## Enqueuing

      PollDataSource.enqueue(integration_id)

  ## Flow

  1. Load integration + credential
  2. Check integration is still active
  3. Call provider.poll/2
  4. Run ProcessIngestion to store + classify + threshold check
  5. Record sync timestamp
  6. Re-enqueue self with configured delay
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: 300, keys: [:integration_id]]

  require Logger

  alias Magus.Integrations
  alias Magus.Integrations.ProcessIngestion

  @failure_threshold 10

  @doc """
  Enqueue a poll job for the given integration. Idempotent within 5 minutes.
  """
  def enqueue(integration_id) do
    %{integration_id: integration_id}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @doc """
  Enqueue a poll job with a delay (in minutes).
  """
  def enqueue(integration_id, delay_minutes) when is_integer(delay_minutes) do
    %{integration_id: integration_id}
    |> __MODULE__.new(scheduled_at: DateTime.add(DateTime.utc_now(), delay_minutes * 60, :second))
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"integration_id" => integration_id}}) do
    with {:ok, integration} <- load_integration(integration_id),
         :ok <- check_active(integration),
         {:ok, provider_module} <- get_provider(integration),
         {:ok, credential} <- load_credential(integration) do
      case provider_module.poll(integration, credential) do
        {:ok, raw_entries} ->
          handle_poll_success(integration_id, integration, provider_module, raw_entries)

        {:error, reason} ->
          handle_poll_failure(integration_id, integration, reason)
      end
    else
      {:cancel, reason} ->
        {:cancel, reason}

      {:error, reason} ->
        Logger.warning("PollDataSource failed for #{integration_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_poll_success(integration_id, integration, provider_module, raw_entries) do
    ProcessIngestion.run_with_entries(provider_module, integration, raw_entries)

    Integrations.record_integration_sync(integration, authorize?: false)
    Integrations.record_integration_poll_success(integration, authorize?: false)

    interval = get_in(integration.config, ["poll_interval_minutes"]) || 30
    enqueue(integration_id, interval)

    :ok
  end

  defp handle_poll_failure(integration_id, integration, reason) do
    Logger.warning("PollDataSource failed for #{integration_id}: #{inspect(reason)}")

    {:ok, updated} =
      Integrations.record_integration_poll_failure(integration, %{last_error: inspect(reason)},
        authorize?: false
      )

    if updated.consecutive_failures >= @failure_threshold do
      handle_threshold_reached(integration_id, updated)
    else
      interval = get_in(integration.config, ["poll_interval_minutes"]) || 30
      enqueue(integration_id, interval)
    end

    {:error, reason}
  end

  defp handle_threshold_reached(integration_id, integration) do
    already_errored? = integration.status == :error

    {:ok, errored} = Integrations.mark_integration_errored(integration, authorize?: false)

    unless already_errored? do
      notify_owner_of_error(errored)
    end

    Logger.warning(
      "PollDataSource: integration #{integration_id} hit #{@failure_threshold} " <>
        "consecutive failures, marking :error and stopping re-enqueue"
    )
  end

  defp notify_owner_of_error(integration) do
    case Magus.Notifications.create_notification(
           %{
             user_id: integration.user_id,
             notification_type: :system,
             title: "Integration disabled after repeated failures",
             body:
               "An integration failed to poll #{@failure_threshold} times in a row and has " <>
                 "been paused. Last error: #{integration.last_error || "unknown"}",
             metadata: %{
               user_integration_id: integration.id,
               provider_key: integration.provider_key,
               consecutive_failures: integration.consecutive_failures
             }
           },
           authorize?: false
         ) do
      {:ok, _notification} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "PollDataSource: failed to notify owner for integration #{integration.id}: #{inspect(error)}"
        )

        :ok
    end
  end

  defp load_integration(id) do
    case Integrations.get_user_integration(id, authorize?: false) do
      {:ok, nil} ->
        {:cancel, :integration_not_found}

      {:ok, integration} ->
        {:ok, integration}

      {:error, %Ash.Error.Query.NotFound{}} ->
        {:cancel, :integration_not_found}

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        {:cancel, :integration_not_found}

      {:error, _} ->
        {:cancel, :integration_not_found}
    end
  end

  defp check_active(%{status: :active}), do: :ok
  defp check_active(_), do: {:cancel, :integration_inactive}

  defp get_provider(integration) do
    case Integrations.get_provider_module(integration.provider_key) do
      nil ->
        {:cancel, :unknown_provider}

      mod ->
        if function_exported?(mod, :poll, 2) do
          {:ok, mod}
        else
          {:cancel, :provider_not_pollable}
        end
    end
  end

  defp load_credential(integration) do
    case Integrations.get_credential_for_integration(integration.id, authorize?: false) do
      {:ok, credential} -> {:ok, credential}
      {:error, _} -> {:ok, nil}
    end
  end
end
