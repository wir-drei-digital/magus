defmodule MagusWeb.Workbench.Components.InlineEditActions do
  @moduledoc """
  Save (checkmark) + cancel (x) buttons rendered next to inline edit inputs
  (rename brain page title, create folder, rename conversation, ...). The
  save button is a form submit; cancel is a click that fires `cancel_event`
  on the given target. Same visual language across every inline edit so the
  flow is recognizable on mobile where keyboard-only Enter/Escape isn't
  obvious.
  """

  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.CoreComponents, only: [icon: 1]

  attr :cancel_event, :string, required: true, doc: "phx-click event for cancel"
  attr :target, :any, default: nil, doc: "phx-target for the cancel event"
  attr :save_label, :string, default: nil, doc: "Override save button label/title"
  attr :cancel_label, :string, default: nil, doc: "Override cancel button label/title"
  attr :size, :atom, values: [:sm, :md], default: :md

  def inline_edit_actions(assigns) do
    assigns =
      assigns
      |> assign_new(:save_label, fn -> gettext("Save") end)
      |> assign_new(:cancel_label, fn -> gettext("Cancel") end)
      |> assign(:button_class, button_class(assigns[:size] || :md))
      |> assign(:icon_class, icon_class(assigns[:size] || :md))

    ~H"""
    <button
      type="submit"
      class={[@button_class, "text-success"]}
      title={@save_label}
      aria-label={@save_label}
    >
      <.icon name="lucide-check" class={@icon_class} />
    </button>
    <button
      type="button"
      phx-click={@cancel_event}
      phx-target={@target}
      class={[@button_class, "text-error"]}
      title={@cancel_label}
      aria-label={@cancel_label}
    >
      <.icon name="lucide-x" class={@icon_class} />
    </button>
    """
  end

  defp button_class(:sm),
    do: "w-6 h-6 rounded hover:bg-wb-hover flex items-center justify-center shrink-0"

  defp button_class(:md),
    do: "w-7 h-7 rounded-md hover:bg-wb-hover flex items-center justify-center shrink-0"

  defp icon_class(:sm), do: "w-3.5 h-3.5"
  defp icon_class(:md), do: "w-4 h-4"
end
