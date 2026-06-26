defmodule MagusWeb.Workbench.Layout.ModePicker do
  @moduledoc """
  Row (or column) of mode icon buttons. Reused by the desktop ModeStrip
  (vertical) and the mobile Drawer (horizontal). Stateless. Emits the
  existing `select_mode` event with `phx-value-mode=<key>`.

  The `:horizontal` layout fills its container width and adds inset padding,
  matching the upcoming mobile drawer wrap. Callers using `:horizontal` in
  other contexts may need to override these classes.
  """
  use MagusWeb, :html

  alias MagusWeb.Workbench.Modes

  attr :current_mode, :atom, required: true
  attr :layout, :atom, values: [:vertical, :horizontal], default: :vertical
  attr :detail_view_active?, :boolean, default: false

  def mode_picker(assigns) do
    assigns = assign(assigns, :modes, Modes.all())

    ~H"""
    <div
      data-mode-picker
      data-mode-picker-layout={@layout}
      class={[
        "flex items-center",
        @layout == :vertical && "flex-col gap-1.5",
        @layout == :horizontal && "flex-row gap-2 justify-center w-full px-2"
      ]}
    >
      <button
        :for={mode <- @modes}
        type="button"
        data-mode-icon={mode.key}
        data-active={to_string(!@detail_view_active? && @current_mode == mode.key)}
        phx-click="select_mode"
        phx-value-mode={mode.key}
        class={[
          "tooltip w-10 h-10 rounded-lg flex items-center justify-center transition-colors cursor-pointer",
          @layout == :vertical && "tooltip-right",
          @layout == :horizontal && "tooltip-top",
          cond do
            @detail_view_active? -> "hover:bg-wb-hover text-wb-text-muted opacity-60"
            @current_mode == mode.key -> "text-wb-text"
            true -> "hover:bg-wb-hover text-wb-text-muted"
          end
        ]}
        aria-label={mode.label}
        data-tip={mode.label}
      >
        <.icon name={mode.icon} class="w-5 h-5" />
      </button>
    </div>
    """
  end
end
