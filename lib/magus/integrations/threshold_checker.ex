defmodule Magus.Integrations.ThresholdChecker do
  @moduledoc """
  Stateless module that delegates inbox event decisions to data source providers
  and handles shared event creation boilerplate (user loading, idempotency, error handling).
  """

  require Logger

  @doc """
  Check newly ingested entries against the provider's threshold logic.

  Delegates to the provider's `should_create_inbox_event?/2` and
  `build_inbox_event_attrs/2` callbacks. If either callback is not implemented,
  returns `{:ok, :below_threshold}`.

  Returns `{:ok, :escalated}`, `{:ok, :below_threshold}`, or `{:error, reason}`.
  """
  def check(integration, new_entries, provider_module) when is_list(new_entries) do
    if implements_inbox_callbacks?(provider_module) and
         provider_module.should_create_inbox_event?(integration, new_entries) do
      attrs =
        provider_module.build_inbox_event_attrs(integration, new_entries)
        |> apply_urgency_override(integration)

      create_inbox_event(integration, attrs)
    else
      {:ok, :below_threshold}
    end
  end

  defp implements_inbox_callbacks?(module) do
    function_exported?(module, :should_create_inbox_event?, 2) and
      function_exported?(module, :build_inbox_event_attrs, 2)
  end

  defp apply_urgency_override(attrs, %{config: %{"urgency_override" => "immediate"}}),
    do: Map.put(attrs, :urgency, :immediate)

  defp apply_urgency_override(attrs, %{config: %{"urgency_override" => "deferred"}}),
    do: Map.put(attrs, :urgency, :deferred)

  defp apply_urgency_override(attrs, _integration), do: attrs

  defp create_inbox_event(integration, attrs) do
    integration = ensure_loaded(integration)
    user = get_user(integration)

    case Magus.Agents.create_inbox_event(attrs, actor: user) do
      {:ok, _event} ->
        Logger.info("ThresholdChecker: escalated for integration #{integration.id}")
        {:ok, :escalated}

      {:error, error} ->
        if idempotency_error?(error) do
          {:ok, :below_threshold}
        else
          {:error, error}
        end
    end
  end

  defp ensure_loaded(%{user: %Ash.NotLoaded{}} = integration) do
    Ash.load!(integration, [:user], authorize?: false)
  end

  defp ensure_loaded(integration), do: integration

  defp get_user(%{user: %Magus.Accounts.User{} = user}), do: user

  defp get_user(%{user_id: user_id}) do
    Magus.Accounts.get_user!(user_id, authorize?: false)
  end

  defp idempotency_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidChanges{message: msg} ->
        String.contains?(to_string(msg), "idempotency")

      %{fields: fields} ->
        :idempotency_key in (fields || [])

      _ ->
        false
    end)
  end

  defp idempotency_error?(_), do: false
end
