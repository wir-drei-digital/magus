defmodule MagusWeb.ChatLive.Components.Message.CollapsibleSection do
  @moduledoc """
  A reusable collapsible section component using HTML details/summary elements.

  Provides a consistent pattern for expandable content with:
  - A summary line that's always visible (clickable to expand/collapse)
  - Expandable content revealed when opened
  - Tree-style prefix (└) for nested appearance
  - Support for different visual styles (default, warning, error)

  ## Examples

      # Simple collapsible with text summary
      <.collapsible summary="Show details">
        <p>Hidden content here</p>
      </.collapsible>

      # With duration
      <.collapsible summary="Completed successfully" duration_ms={150}>
        <pre>Output content</pre>
      </.collapsible>

      # Error style
      <.collapsible summary="Error occurred" variant={:error}>
        <pre>Error details</pre>
      </.collapsible>
  """
  use MagusWeb, :html

  import MagusWeb.Live.Shared.ComponentUtils, only: [format_execution_time: 1]

  @doc """
  Renders a collapsible section with summary and expandable content.

  All instances have consistent styling with tree-prefix and indentation.
  """
  attr :summary, :string, required: true, doc: "Text displayed in the summary (always visible)"
  attr :duration_ms, :integer, default: nil, doc: "Optional duration to display"
  attr :variant, :atom, default: :default, values: [:default, :warning, :error]
  attr :open, :boolean, default: false, doc: "Whether the section starts expanded"

  slot :inner_block, required: true, doc: "The expandable content"
  slot :suffix, doc: "Optional content to render after the summary text (e.g., timestamp)"

  def collapsible(assigns) do
    summary_styles = summary_variant_styles(assigns.variant)
    assigns = assign(assigns, summary_styles: summary_styles)

    ~H"""
    <details class="mt-1 ml-3" open={@open}>
      <summary class={[
        "text-xs cursor-pointer flex items-center gap-2",
        @summary_styles
      ]}>
        <span class="text-base-content/40">└</span>
        <span>{@summary}</span>
        <span :if={@duration_ms} class="text-base-content/40">
          ({format_execution_time(@duration_ms)})
        </span>
      </summary>
      <div class="mt-1 ml-1 text-xs border-l-2 border-base-300 pl-3">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  @doc """
  Renders a non-collapsible inline summary line (for when there's nothing to expand).
  """
  attr :summary, :string, required: true
  attr :duration_ms, :integer, default: nil
  attr :variant, :atom, default: :default, values: [:default, :warning, :error]

  def inline_summary(assigns) do
    text_styles = text_variant_styles(assigns.variant)
    assigns = assign(assigns, text_styles: text_styles)

    ~H"""
    <div class={["ml-3 text-xs flex items-center gap-2 mt-0.5", @text_styles]}>
      <span class="text-base-content/40">└</span>
      <span>{@summary}</span>
      <span :if={@duration_ms} class="text-base-content/40">
        ({format_execution_time(@duration_ms)})
      </span>
    </div>
    """
  end

  @doc """
  Renders a pre-formatted code/output block with appropriate styling.

  When `id` is provided, enables a copy-to-clipboard button and syntax highlighting.
  Pass `language` (e.g., "python") to enable highlight.js syntax coloring.
  """
  attr :content, :string, required: true
  attr :variant, :atom, default: :default, values: [:default, :warning, :error]
  attr :max_height, :string, default: "max-h-64"
  attr :id, :string, default: nil
  attr :language, :string, default: nil

  def code_block(assigns) do
    bg_styles = bg_variant_styles(assigns.variant)
    text_styles = code_text_variant_styles(assigns.variant)
    assigns = assign(assigns, bg_styles: bg_styles, text_styles: text_styles)

    ~H"""
    <div
      :if={@id}
      id={@id}
      phx-hook="ToolCodeBlock"
      class="relative group/code"
    >
      <button
        type="button"
        data-copy-btn
        class="absolute top-1.5 right-1.5 btn btn-ghost btn-xs h-6 min-h-6 px-1.5 opacity-0 group-hover/code:opacity-100 transition-opacity z-10 bg-base-300/80 hover:bg-base-300"
        title="Copy"
      >
        <span data-icon="copy"><.icon name="lucide-clipboard" class="w-3 h-3" /></span>
        <span data-icon="check" class="hidden">
          <.icon name="lucide-check" class="w-3 h-3 text-success" />
        </span>
      </button>
      <pre class={[
        "rounded p-2 pr-8 text-xs overflow-x-auto overflow-y-auto whitespace-pre-wrap",
        @max_height,
        @bg_styles,
        @text_styles
      ]}><code class={@language && "language-#{@language}"}>{@content}</code></pre>
    </div>
    <pre
      :if={!@id}
      class={[
        "rounded p-2 text-xs overflow-x-auto overflow-y-auto whitespace-pre-wrap",
        @max_height,
        @bg_styles,
        @text_styles
      ]}
    ><code>{@content}</code></pre>
    """
  end

  # Variant-specific styles

  defp summary_variant_styles(:default), do: "text-base-content/50 hover:text-base-content/70"
  defp summary_variant_styles(:warning), do: "text-warning/70 hover:text-warning/90"
  defp summary_variant_styles(:error), do: "text-error/70 hover:text-error/90"

  defp text_variant_styles(:default), do: "text-base-content/60"
  defp text_variant_styles(:warning), do: "text-warning/80"
  defp text_variant_styles(:error), do: "text-error/80"

  defp bg_variant_styles(:default), do: "bg-base-300/50"
  defp bg_variant_styles(:warning), do: "bg-warning/10"
  defp bg_variant_styles(:error), do: "bg-error/10"

  defp code_text_variant_styles(:default), do: "text-base-content/80"
  defp code_text_variant_styles(:warning), do: "text-warning/90"
  defp code_text_variant_styles(:error), do: "text-error/90"
end
