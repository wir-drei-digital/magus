defmodule MagusWeb.Knowledge.Components.KnowledgeSourceCard do
  @moduledoc """
  Shared function components for knowledge source UI: provider icons and sync status badges.
  """

  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  # ---------------------------------------------------------------------------
  # Provider Icon
  # ---------------------------------------------------------------------------

  @doc """
  Renders a provider icon in a colored background circle.

  ## Attributes

    * `:provider` - Provider atom (required). One of :google_drive, :notion, :nextcloud, :affine, or any other atom.
    * `:size` - Icon size: :sm, :md, or :lg. Defaults to :md.
  """
  attr :provider, :atom, required: true
  attr :size, :atom, default: :md

  def provider_icon(assigns) do
    size_class = size_classes(assigns.size)

    assigns = assign(assigns, :size_class, size_class)

    ~H"""
    <MagusWeb.BrandIcons.provider_icon provider={@provider} class={@size_class} />
    """
  end

  defp size_classes(:sm), do: "size-8"
  defp size_classes(:md), do: "size-10"
  defp size_classes(:lg), do: "size-12"

  # ---------------------------------------------------------------------------
  # Sync Status Badge
  # ---------------------------------------------------------------------------

  @doc """
  Renders a DaisyUI badge for sync/connection status.

  ## Attributes

    * `:status` - Status atom (required). One of :synced, :syncing, :error, :pending, :active, :disabled.
  """
  attr :status, :atom, required: true

  def sync_status_badge(assigns) do
    assigns =
      assigns
      |> assign(:badge_class, status_badge_class(assigns.status))
      |> assign(:label, status_label(assigns.status))

    ~H"""
    <span class={["badge badge-sm gap-1", @badge_class]}>
      <span :if={@status == :syncing} class="loading loading-spinner loading-xs"></span>
      {@label}
    </span>
    """
  end

  defp status_badge_class(:synced), do: "badge-success"
  defp status_badge_class(:syncing), do: "badge-info"
  defp status_badge_class(:error), do: "badge-error"
  defp status_badge_class(:pending), do: "badge-ghost"
  defp status_badge_class(:active), do: "badge-success"
  defp status_badge_class(:disabled), do: "badge-ghost"
  defp status_badge_class(_), do: "badge-ghost"

  defp status_label(:synced), do: gettext("Synced")
  defp status_label(:syncing), do: gettext("Syncing")
  defp status_label(:error), do: gettext("Error")
  defp status_label(:pending), do: gettext("Pending")
  defp status_label(:active), do: gettext("Active")
  defp status_label(:disabled), do: gettext("Disabled")
  defp status_label(_), do: gettext("Unknown")
end
