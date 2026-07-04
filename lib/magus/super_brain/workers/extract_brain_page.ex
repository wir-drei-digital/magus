defmodule Magus.SuperBrain.Workers.ExtractBrainPage do
  @moduledoc """
  Extracts entities and edges from a brain page's markdown `body` into the
  brain's FalkorDB graph (`brain:<brain_id>`).

  The pipeline is implemented by `Magus.SuperBrain.Workers.ExtractBase`;
  this module only implements the resource-specific `load/1`. Whole-page
  extraction: the page body is the unit, keyed on `page.id`.

  Accepted arg keys: `"resource_id"` (preferred) or `"page_id"` (legacy).

  Enqueued via `Magus.Brain.Page.Changes.EnqueueSuperBrainExtraction`, an
  `after_action` on `Page.update_body`.
  """

  use Magus.SuperBrain.Workers.ExtractBase, queue: :super_brain_extraction

  @extractor_version "brain_extract_worker@2026-07-04-claims"

  @impl true
  def extractor_version, do: @extractor_version

  @impl true
  def load(%{"resource_id" => page_id}) when is_binary(page_id), do: do_load(page_id)
  def load(%{"page_id" => page_id}) when is_binary(page_id), do: do_load(page_id)
  def load(_), do: {:error, :missing_resource_id}

  defp do_load(page_id) do
    with {:ok, page} <- Ash.get(Magus.Brain.Page, page_id, load: [:brain], authorize?: false),
         {:ok, user_id} <- resolve_user_id(page) do
      body = page.body || ""

      {:ok,
       %{
         user_id: user_id,
         raw_text: body,
         graph_name: "brain:#{page.brain_id}",
         resource_type: :brain_page,
         resource_id: page.id,
         source_weight: 1.5,
         extra_node_props: %{},
         ontology_source: ontology_source_for_body(body)
       }}
    else
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :page_not_found}
      {:error, _} = err -> err
      _ -> {:error, :page_not_found}
    end
  end

  defp resolve_user_id(%Magus.Brain.Page{brain: %{user_id: user_id}})
       when is_binary(user_id),
       do: {:ok, user_id}

  defp resolve_user_id(_), do: {:error, :page_user_not_resolvable}

  # Markdown equivalent of the old "important callout" curation signal: a page
  # whose body contains an `insight` callout fence (the brain editor's "key
  # takeaway" callout, one of insight/warning/question/note) routes through
  # `:user_curated` so high-confidence facts can reach the `:instruction` tier.
  # Everything else is `:llm_extract`.
  defp ontology_source_for_body(body) when is_binary(body) do
    if insight_callout?(body), do: :user_curated, else: :llm_extract
  end

  defp ontology_source_for_body(_), do: :llm_extract

  defp insight_callout?(body) do
    body
    |> String.split("\n")
    |> scan_callouts(false)
  end

  defp scan_callouts([], _inside), do: false

  defp scan_callouts([line | rest], inside) do
    trimmed = String.trim(line)

    cond do
      not inside and trimmed == "```callout" -> scan_callouts(rest, true)
      inside and trimmed == "```" -> scan_callouts(rest, false)
      inside and String.match?(trimmed, ~r/^variant:\s*insight\s*$/) -> true
      true -> scan_callouts(rest, inside)
    end
  end
end
