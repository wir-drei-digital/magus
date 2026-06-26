defmodule Magus.SuperBrain.Workers.ExtractMemory do
  @moduledoc """
  Extracts entities and edges from memories into the appropriate memories graph.

  Routing:
    scope == :user, workspace_id == nil   ->  memories:user:<user_id>
    scope == :user, workspace_id == ws    ->  memories:workspace:<ws>
    scope == :agent                       ->  memories:user:<owner_user_id>
                                              with custom_agent_id as a node property
    scope == :local                       ->  not extracted (filtered upstream)

  Pipeline implemented by `Magus.SuperBrain.Workers.ExtractBase`. This module
  only implements the resource-specific `load/1` callback. The base handles
  fingerprint gating, budget killswitch, Episode lifecycle, MessageUsage
  writes, and graph writes.

  Memories prefer `summary` (the canonical text representation) and fall
  back to rendering `content` when summary is nil.
  """

  use Magus.SuperBrain.Workers.ExtractBase, queue: :super_brain_extraction

  @extractor_version "memory_extract_worker@2026-05-21"

  @impl true
  def extractor_version, do: @extractor_version

  # Iter4 Task 4: high-confidence Memory kinds (`:fact`, `:preference`) carry
  # explicit, stable user knowledge and route through `:memory_explicit` so
  # well-confident extractions can reach the `:instruction` trust tier. The
  # full Memory.kind enum is `:general | :fact | :hypothesis | :observation |
  # :summary | :preference | :goal | :topic | :habit | :reflection`; only
  # `:fact` and `:preference` represent first-person explicit knowledge in
  # the sense the trust-tier ladder cares about. Everything else stays at
  # `:llm_extract`.
  @explicit_memory_kinds [:fact, :preference]

  @impl true
  def load(%{"resource_id" => memory_id}) when is_binary(memory_id) do
    case Ash.get(Magus.Memory.Memory, memory_id, authorize?: false) do
      {:ok, memory} ->
        case route(memory) do
          {:ok, graph_name, extra_props} ->
            raw_text = memory.summary || render_content(memory.content) || ""

            {:ok,
             %{
               user_id: memory.user_id,
               raw_text: raw_text,
               graph_name: graph_name,
               resource_type: :memory,
               resource_id: memory.id,
               source_weight: 1.0,
               extra_node_props: extra_props,
               ontology_source: ontology_source_for_memory(memory)
             }}

          {:error, _} = err ->
            err
        end

      {:error, %Ash.Error.Query.NotFound{}} ->
        {:error, :memory_not_found}

      {:error, _} = err ->
        err
    end
  end

  def load(_), do: {:error, :missing_resource_id}

  defp ontology_source_for_memory(%Magus.Memory.Memory{kind: kind})
       when kind in @explicit_memory_kinds,
       do: :memory_explicit

  defp ontology_source_for_memory(_), do: :llm_extract

  # ---------------------------------------------------------------------------
  # Graph routing
  # ---------------------------------------------------------------------------

  defp route(%{scope: :user, workspace_id: nil, user_id: uid}) when is_binary(uid) do
    {:ok, "memories:user:#{uid}", %{}}
  end

  defp route(%{scope: :user, workspace_id: ws_id}) when is_binary(ws_id) do
    {:ok, "memories:workspace:#{ws_id}", %{}}
  end

  defp route(%{scope: :agent, user_id: uid, custom_agent_id: agent_id})
       when is_binary(uid) and is_binary(agent_id) do
    {:ok, "memories:user:#{uid}", %{custom_agent_id: agent_id}}
  end

  defp route(%{scope: :local}), do: {:error, :local_memory_not_extracted}
  defp route(_), do: {:error, :unrouteable_memory}

  # Memories carry a structured map in `content`. Prefer the canonical
  # `summary` upstream; this is only a fallback when summary is nil.
  defp render_content(nil), do: nil
  defp render_content(content) when content == %{}, do: nil

  defp render_content(content) when is_map(content) do
    content[:text] || content["text"] || content[:body] || content["body"] || inspect(content)
  end
end
