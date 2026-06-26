defmodule MagusWeb.Components.Modal do
  @moduledoc """
  A unified modal component for consistent modal dialogs.

  ## Features

  - Uses DaisyUI's modal pattern with `<dialog>` element
  - Supports size variants: sm, md (default), lg, xl
  - Configurable close behavior via `on_close` (JS command or event string)
  - Optional `target` for LiveComponent event targeting
  - Slots for title, content, and actions

  ## Usage

  Basic modal with all slots:

      <.modal show={@show_modal} on_close="close_modal">
        <:title>Modal Title</:title>
        Your content here
        <:actions>
          <button class="btn" phx-click="close_modal">Cancel</button>
          <button class="btn btn-primary" phx-click="save">Save</button>
        </:actions>
      </.modal>

  LiveComponent modal with target:

      <.modal show={@show} on_close="cancel" target={@myself}>
        <:title>Edit Item</:title>
        <.form for={@form} phx-submit="save" phx-target={@myself}>
          ...
        </.form>
        <:actions>
          <button type="submit" class="btn btn-primary">Save</button>
        </:actions>
      </.modal>

  With JS close command:

      <.modal show={@show} on_close={JS.push("close") |> JS.hide(to: "#my-modal")}>
        ...
      </.modal>
  """
  use Phoenix.Component

  import MagusWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders a modal dialog.

  ## Attributes

  - `id` - Modal ID (default: "modal")
  - `show` - Whether the modal is visible (required)
  - `on_close` - Close handler: event name string or JS command struct
  - `target` - LiveComponent target for phx-target (optional)
  - `size` - Modal size: :sm, :md, :lg, :xl (default: :md)
  - `close_on_backdrop` - Whether clicking backdrop closes modal (default: true)
  - `close_on_escape` - Whether pressing Escape closes modal (default: true)

  ## Slots

  - `title` - Modal header/title content
  - `inner_block` - Main modal content (required)
  - `actions` - Modal footer actions (buttons, links, etc.)
  """
  attr :id, :string, default: "modal"
  attr :show, :boolean, required: true
  attr :on_close, :any, default: nil, doc: "Event name or JS command for close action"
  attr :target, :any, default: nil, doc: "LiveComponent target for phx-target"
  attr :size, :atom, default: :md, values: [:sm, :md, :lg, :xl]
  attr :close_on_backdrop, :boolean, default: true
  attr :close_on_escape, :boolean, default: true

  slot :title
  slot :inner_block, required: true
  slot :actions

  def modal(assigns) do
    size_class =
      case assigns.size do
        :sm -> "max-w-sm"
        :md -> "max-w-lg"
        :lg -> "max-w-2xl"
        :xl -> "max-w-4xl"
      end

    assigns = assign(assigns, :size_class, size_class)

    ~H"""
    <dialog
      id={@id}
      class={"modal #{if @show, do: "modal-open"}"}
      {escape_attrs(@close_on_escape, @on_close, @target)}
    >
      <div class={"modal-box #{@size_class}"}>
        <%!-- Header with title and close button --%>
        <div :if={@title != []} class="flex items-center justify-between mb-4">
          <h3 class="font-bold text-lg">
            {render_slot(@title)}
          </h3>
          <button
            :if={@on_close}
            type="button"
            class="btn btn-sm btn-circle btn-ghost"
            {close_attrs(@on_close, @target)}
          >
            <.icon name="lucide-x" class="w-5 h-5" />
          </button>
        </div>

        <%!-- Main content --%>
        {render_slot(@inner_block)}

        <%!-- Actions footer --%>
        <div :if={@actions != []} class="modal-action">
          {render_slot(@actions)}
        </div>
      </div>

      <%!-- Backdrop --%>
      <div
        :if={@close_on_backdrop && @on_close}
        class="modal-backdrop"
        {close_attrs(@on_close, @target)}
      >
      </div>
    </dialog>
    """
  end

  # Build the close attributes based on whether on_close is a JS command or event name
  defp close_attrs(%Phoenix.LiveView.JS{} = js, _target) do
    %{"phx-click" => js}
  end

  defp close_attrs(event, target) when is_binary(event) do
    attrs = %{"phx-click" => event}

    if target do
      Map.put(attrs, "phx-target", target)
    else
      attrs
    end
  end

  defp close_attrs(nil, _target), do: %{}

  # Build escape key attributes for the dialog element
  defp escape_attrs(true, %Phoenix.LiveView.JS{} = js, _target) do
    %{"phx-window-keydown" => js, "phx-key" => "Escape"}
  end

  defp escape_attrs(true, event, target) when is_binary(event) do
    attrs = %{"phx-window-keydown" => event, "phx-key" => "Escape"}

    if target do
      Map.put(attrs, "phx-target", target)
    else
      attrs
    end
  end

  defp escape_attrs(_, _, _), do: %{}
end
