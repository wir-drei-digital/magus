defmodule MagusWeb.Workbench.Components.WorkspaceShareButton do
  @moduledoc """
  Header-level "Share with workspace" toggle used by workbench resource
  views (chats, prompts, agents, brains, ...).

  The component renders nothing for personal resources (no `workspace_id`)
  and otherwise toggles between a Share and Shared state based on the
  resource's `is_shared_to_workspace` calc. Click events `share_to_workspace`
  and `unshare_from_workspace` bubble to the parent LiveView, which is
  expected to call `MagusWeb.Workbench.WorkspaceShare.share/3` / `unshare/3`
  and refresh the resource so the calc updates.
  """

  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.CoreComponents, only: [icon: 1]

  attr :resource, :map,
    required: true,
    doc: "Resource exposing `:workspace_id` and `:is_shared_to_workspace` (loaded calc)"

  attr :class, :string, default: "wb-pill-btn"

  def workspace_share_button(assigns) do
    ~H"""
    <button
      :if={@resource.workspace_id && not @resource.is_shared_to_workspace}
      type="button"
      data-action="share-to-workspace"
      phx-click="share_to_workspace"
      class={@class}
      title={gettext("Share with the workspace")}
    >
      <.icon name="lucide-users" class="w-4 h-4" />
      <span>{gettext("Share with workspace")}</span>
    </button>
    <button
      :if={@resource.workspace_id && @resource.is_shared_to_workspace}
      type="button"
      data-action="unshare-from-workspace"
      phx-click="unshare_from_workspace"
      class={@class}
      title={gettext("Stop sharing with the workspace")}
    >
      <.icon name="lucide-user-check" class="w-4 h-4" />
      <span>{gettext("Shared with workspace")}</span>
    </button>
    """
  end
end
