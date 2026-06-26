defmodule MagusWeb.Components.ActionCards do
  @moduledoc """
  A reusable component for rendering interactive action cards.

  Supports two layouts:
  - `"grid"` — 2-column grid with icon + title + description
  - `"list"` — single column with letter labels (A, B, C...) + title + description

  Action types:
  - `"navigate"` — renders as a `<.link>` for client-side navigation
  - `"send_message"` / `"prefill"` — renders as a clickable div emitting `action_card_click`

  ## Usage

      <ActionCards.action_cards action_cards={@action_cards} />

  Where `@action_cards` is a map like:

      %{
        "layout" => "grid",
        "cards" => [
          %{
            "icon" => "pencil",
            "title" => "Create a prompt",
            "description" => "Save reusable instructions",
            "action" => %{"type" => "send_message", "payload" => "Help me create a prompt"}
          }
        ]
      }
  """
  use Phoenix.Component

  attr :action_cards, :map, default: nil
  attr :conversation_id, :string, default: nil

  def action_cards(assigns) do
    if assigns.action_cards == nil do
      ~H""
    else
      assigns =
        assigns
        |> assign(:layout, assigns.action_cards["layout"] || "grid")
        |> assign(:cards, assigns.action_cards["cards"] || [])
        |> assign(:indexed_cards, index_cards(assigns.action_cards["cards"] || []))

      ~H"""
      <div :if={@cards != []} class={layout_class(@layout)}>
        <.action_card
          :for={{card, index} <- @indexed_cards}
          card={card}
          index={index}
          layout={@layout}
          conversation_id={@conversation_id}
        />
      </div>
      """
    end
  end

  attr :card, :map, required: true
  attr :index, :integer, required: true
  attr :layout, :string, required: true
  attr :conversation_id, :string, default: nil

  defp action_card(assigns) do
    case assigns.card["action"]["type"] do
      "navigate" ->
        payload = assigns.card["action"]["payload"] || ""

        if String.starts_with?(payload, "/") and not String.starts_with?(payload, "//") do
          ~H"""
          <.link
            navigate={@card["action"]["payload"]}
            class="card border border-wb-border-strong bg-wb-surface hover:border-primary transition-colors cursor-pointer"
          >
            <div class="card-body p-4">
              <.card_content card={@card} index={@index} layout={@layout} />
            </div>
          </.link>
          """
        else
          ~H"""
          <div class="card border border-wb-border-strong bg-wb-surface">
            <div class="card-body p-4">
              <.card_content card={@card} index={@index} layout={@layout} />
            </div>
          </div>
          """
        end

      _type ->
        ~H"""
        <div
          phx-click="action_card_click"
          phx-value-type={@card["action"]["type"]}
          phx-value-payload={@card["action"]["payload"]}
          phx-value-conversation-id={@conversation_id}
          class="card border border-wb-border-strong bg-wb-surface hover:border-primary transition-colors cursor-pointer"
        >
          <div class="card-body p-4">
            <.card_content card={@card} index={@index} layout={@layout} />
          </div>
        </div>
        """
    end
  end

  attr :card, :map, required: true
  attr :index, :integer, required: true
  attr :layout, :string, required: true

  defp card_content(assigns) do
    case assigns.layout do
      "list" ->
        ~H"""
        <div class="flex items-start gap-3">
          <span class="text-primary font-bold text-sm">{letter_label(@index)}</span>
          <div>
            <div class="font-semibold text-sm text-base-content">{@card["title"]}</div>
            <div :if={@card["description"]} class="text-xs text-base-content/60 mt-1">
              {@card["description"]}
            </div>
          </div>
        </div>
        """

      _grid ->
        ~H"""
        <div class="flex flex-row gap-2 items-start">
          <.card_icon :if={@card["icon"]} icon={@card["icon"]} class="mb-1" />
          <div>
            <div class="font-semibold text-sm text-base-content">{@card["title"]}</div>
            <div :if={@card["description"]} class="text-xs text-base-content/60 mt-1">
              {@card["description"]}
            </div>
          </div>
        </div>
        """
    end
  end

  attr :icon, :string, required: true
  attr :class, :string, default: ""

  defp card_icon(%{icon: "lucide-" <> _} = assigns) do
    ~H"""
    <div class={[@icon, "w-5 h-5 text-primary", @class]} aria-hidden="true" />
    """
  end

  defp card_icon(assigns) do
    ~H"""
    <div class={["text-xl", @class]}>{@icon}</div>
    """
  end

  defp layout_class("list"), do: "flex flex-col gap-2"
  defp layout_class(_grid), do: "grid grid-cols-2 gap-3"

  defp index_cards(cards), do: Enum.with_index(cards)

  defp letter_label(index) when index >= 0 and index < 26, do: <<?A + index::utf8>>
  defp letter_label(index), do: to_string(index + 1)
end
