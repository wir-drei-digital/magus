defmodule MagusWeb.Workbench.Mobile.Chrome do
  @moduledoc """
  Mobile-only socket assigns derived from the active tab. Memoized into
  assigns so the workbench main render doesn't recompute the variant on
  every text.chunk PubSub broadcast during streaming.
  """

  import Phoenix.Component, only: [assign: 3]

  @spec assign_chrome(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_chrome(socket) do
    assign(socket, :mobile_variant, mobile_variant_for(socket.assigns))
  end

  @spec mobile_variant_for(map()) :: :default | :companion
  def mobile_variant_for(assigns) do
    if companion_for_active_tab(assigns), do: :companion, else: :default
  end

  @spec companion_for_active_tab(map()) :: map() | nil
  def companion_for_active_tab(%{tabs: tabs, active_tab_id: id}) when is_binary(id) do
    case Enum.find(tabs, &(&1["id"] == id)) do
      %{"companion" => spec} when not is_nil(spec) -> spec
      _ -> nil
    end
  end

  def companion_for_active_tab(_), do: nil
end
