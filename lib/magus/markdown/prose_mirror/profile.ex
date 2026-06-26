defmodule Magus.Markdown.ProseMirror.Profile do
  @moduledoc "Hook for domain-specific ProseMirror node lifting/serialization."
  @callback post_process(doc :: map()) :: map()
  @callback node_to_markdown(node :: map()) :: {:ok, String.t()} | :default
  @callback inline_node_to_markdown(node :: map()) :: {:ok, String.t()} | :default

  defmodule Default do
    @behaviour Magus.Markdown.ProseMirror.Profile
    @impl true
    def post_process(doc), do: doc
    @impl true
    def node_to_markdown(_node), do: :default
    @impl true
    def inline_node_to_markdown(_node), do: :default
  end
end
