defmodule MagusWeb.ChatLive.Components.Brain.Blocks.CalloutBlockComponent do
  @moduledoc """
  Renders a callout block with variant-based styling (insight, warning, question),
  icon, label, body text, and optional contributor attribution.

  The body is rendered as markdown so bold/italic/links/lists written by
  agents or pasted by users show up as formatted text rather than literal
  `**syntax**`.
  """

  use MagusWeb, :html

  import MagusWeb.ChatLive.Helpers, only: [to_markdown: 1]

  attr :block, :map, required: true

  def callout_block(assigns) do
    ~H"""
    <div class={["rounded-lg p-3 my-2 not-prose border", callout_classes(@block.content["variant"])]}>
      <div class="flex items-center gap-2 mb-1">
        <span class="text-sm">{callout_icon(@block.content["variant"])}</span>
        <span class="text-xs font-medium">{callout_label(@block.content["variant"])}</span>
        <span
          :if={@block.contributor_type == :custom_agent}
          class="text-xs text-base-content/40 ml-auto"
        >
          {gettext("by agent")}
        </span>
      </div>
      <div class="prose prose-sm dark:prose-invert max-w-none text-sm text-base-content leading-relaxed">
        {to_markdown(@block.content["text"] || "")}
      </div>
    </div>
    """
  end

  defp callout_classes("insight"), do: "bg-success/10 border-success/30"
  defp callout_classes("warning"), do: "bg-warning/10 border-warning/30"
  defp callout_classes("question"), do: "bg-info/10 border-info/30"
  defp callout_classes(_), do: "bg-base-200/50 border-base-300/50"

  defp callout_icon("insight"), do: "💡"
  defp callout_icon("warning"), do: "⚠️"
  defp callout_icon("question"), do: "❓"
  defp callout_icon(_), do: "ℹ️"

  defp callout_label("insight"), do: gettext("Insight")
  defp callout_label("warning"), do: gettext("Warning")
  defp callout_label("question"), do: gettext("Question")
  defp callout_label(_), do: gettext("Note")
end
