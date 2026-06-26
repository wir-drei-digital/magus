defmodule Magus.Brain.Resolver do
  @moduledoc """
  Context-free brain and page resolution.

  Callers pass an actor and explicit identifiers (or nil for auto-discovery).
  No conversation/pane context is read here. The agent-side tool
  `Magus.Agents.Tools.Brain.BrainResolver` wraps this module and adds the
  conversation-context fallbacks.
  """

  alias Magus.Brain

  @doc """
  Resolves a brain id.

    * If `brain_id` is non-nil, returns it as-is (no lookup).
    * If nil, returns the actor's most-recently-updated non-archived brain.

  Options:

    * `:workspace_id` — when provided, auto-discovery scans brains in that
      workspace. When nil, only personal (non-workspace) brains are scanned.
  """
  @spec resolve_brain_id(Ash.Resource.record(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve_brain_id(actor, brain_id, opts \\ [])

  def resolve_brain_id(_actor, brain_id, _opts) when is_binary(brain_id), do: {:ok, brain_id}

  def resolve_brain_id(actor, nil, opts) do
    case list_brains(actor, Keyword.get(opts, :workspace_id)) do
      {:ok, [brain | _]} -> {:ok, brain.id}
      {:ok, []} -> {:error, "No brain found. Create a brain first."}
      {:error, error} -> {:error, "Failed to list brains: #{inspect(error)}"}
    end
  end

  @doc """
  Resolves a page from explicit identifiers.

  Options (in resolution order):

    * `:page_id` - fetch by id
    * `:page_title` - find by title within the given brain
  """
  @spec resolve_page(Ash.Resource.record(), String.t(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, String.t()}
  def resolve_page(actor, brain_id, opts) do
    cond do
      page_id = Keyword.get(opts, :page_id) ->
        fetch_page(page_id, actor)

      page_title = Keyword.get(opts, :page_title) ->
        find_page_by_title(brain_id, page_title, actor)

      true ->
        {:error, "No page specified. Provide :page_id or :page_title."}
    end
  end

  @doc """
  Lists `{brain_id, brain_title}` tuples for the actor.

  Options:

    * `:workspace_id` — when provided, lists workspace brains. When nil,
      lists personal brains.
  """
  @spec list_brain_summaries(Ash.Resource.record(), keyword()) ::
          {:ok, [{String.t(), String.t()}]}
  def list_brain_summaries(actor, opts \\ []) do
    case list_brains(actor, Keyword.get(opts, :workspace_id)) do
      {:ok, brains} -> {:ok, Enum.map(brains, &{&1.id, &1.title})}
      {:error, _} -> {:ok, []}
    end
  end

  defp list_brains(actor, nil), do: Brain.list_brains(actor: actor)

  defp list_brains(actor, workspace_id),
    do: Brain.list_brains_for_workspace(workspace_id, actor: actor)

  defp fetch_page(page_id, actor) do
    case Brain.get_page(page_id, actor: actor) do
      {:ok, page} -> {:ok, page}
      {:error, _} -> {:error, "Page not found with ID: #{page_id}"}
    end
  end

  defp find_page_by_title(brain_id, title, actor) do
    case Brain.find_page_by_title(brain_id, title, actor: actor) do
      {:ok, [page | _]} -> {:ok, page}
      {:ok, []} -> {:error, ~s(No page found with title "#{title}" in this brain.)}
      {:error, error} -> {:error, "Failed to find page by title: #{inspect(error)}"}
    end
  end
end
