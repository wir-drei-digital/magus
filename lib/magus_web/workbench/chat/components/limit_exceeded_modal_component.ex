defmodule MagusWeb.ChatLive.Components.LimitExceededModalComponent do
  @moduledoc """
  Modal component displayed when a user reaches their subscription limit.

  Shows:
  - Which limit was reached
  - Current usage vs limit
  - Upgrade CTA button
  - Close button
  """
  use MagusWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal id="limit-exceeded-modal" show={true} on_close={@on_close}>
        <:title>
          <span class="flex items-center gap-2">
            <.icon name="lucide-alert-triangle" class="h-6 w-6 text-warning" />
            {gettext("Limit Reached")}
          </span>
        </:title>

        <p class="py-4 text-base-content/80">
          {@error.message}
        </p>

        <div
          :if={@error.current != nil and @error.limit != nil}
          class="bg-base-200 rounded-lg p-4 mb-4"
        >
          <div class="flex justify-between text-sm">
            <span class="text-base-content/70">{gettext("Current usage")}:</span>
            <span class="font-medium">
              {format_usage(@error.current, @error.limit_type)} / {format_usage(
                @error.limit,
                @error.limit_type
              )}
            </span>
          </div>
          <div class="w-full bg-base-300 rounded-full h-2 mt-2">
            <div class="h-2 rounded-full bg-error" style="width: 100%"></div>
          </div>
        </div>

        <p class="text-sm text-base-content/60 mb-4">
          {reset_message(@error.limit_type)}
        </p>

        <:actions>
          <button phx-click={@on_close} class="btn btn-ghost">
            {gettext("Close")}
          </button>
          <.link navigate={~p"/settings/subscription"} class="btn btn-primary">
            <.icon name="lucide-arrow-up" class="h-4 w-4 mr-1" />
            {gettext("Upgrade Plan")}
          </.link>
        </:actions>
      </.modal>
    </div>
    """
  end

  defp format_usage(value, :storage), do: MagusWeb.Formatters.format_bytes(value)
  defp format_usage(value, _), do: value

  defp reset_message(:mode_disabled),
    do: gettext("Upgrade your plan to unlock this feature.")

  defp reset_message(:storage_bytes),
    do: gettext("Delete files to free up space, or upgrade your plan for more storage.")

  defp reset_message(:storage_overage),
    do: gettext("Delete files to free up space, or upgrade your plan for more storage.")

  defp reset_message(_), do: ""
end
