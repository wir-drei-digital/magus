defmodule Magus.Agents.Tools.Brain.BrainResolver do
  @moduledoc """
  Brain and page auto-discovery for consolidated brain tools.

  Wraps `Magus.Brain.Resolver` with three additional resolution layers
  driven by Jido tool context:

    1. Explicit param (`brain_id` / `page_id`) - same as the domain module
    2. Active pane context (`brain_id`, `brain_page_id`) - tool-only
    3. Actor's default brain - falls through to `Magus.Brain.Resolver`,
       scoped to `context[:workspace_id]` when present

  The consolidated brain tools (read_brain, edit_brain) call this
  module to auto-resolve brain and page IDs before dispatching to their
  action handlers.
  """

  require Logger
  require Ash.Query

  alias Magus.Brain.Resolver

  import Magus.Agents.Tools.Helpers,
    only: [get_param: 2, get_context_value: 2]

  @doc """
  Resolves a brain ID from params, context, or auto-discovery.

  Resolution order:
  1. `params["brain_id"]` (explicit param). This may be a UUID id, a slug, or
     a title — users commonly name their brain rather than paste an id, so the
     model is allowed to pass any of those.
  2. `context[:brain_id]` (active pane context — set by the authenticated UI)
  3. Actor's most recently updated non-archived brain (via `Magus.Brain.Resolver`),
     scoped to `context[:workspace_id]` when present

  Workspaces stay strictly separated: EVERY path is validated against the
  conversation's workspace (`context[:workspace_id]`). The agent can reach any
  brain in the current workspace but never one in a different workspace —
  whether the id arrives as an explicit param OR from the open pane. The pane
  hint is validated exactly like an explicit id (it used to be trusted blindly,
  which let a cross-workspace brain be used one way and rejected another).
  """
  @spec resolve_brain_id(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_brain_id(context, params) do
    explicit = get_param(params, :brain_id)
    from_context = get_context_value(context, :brain_id)
    actor = get_context_value(context, :user)
    workspace_id = get_context_value(context, :workspace_id)

    cond do
      explicit -> resolve_explicit_brain(explicit, actor, workspace_id)
      from_context -> resolve_explicit_brain(from_context, actor, workspace_id)
      actor -> Resolver.resolve_brain_id(actor, nil, workspace_id: workspace_id)
      true -> {:error, "Missing user context. Cannot resolve brain."}
    end
  end

  # An explicit brain reference from the model may be a UUID id, a slug, or a
  # title. Resolve it to an in-scope brain id while keeping the workspace
  # boundary: a UUID id is matched directly (and rejected when it belongs to a
  # different workspace); a slug/title is matched only against brains reachable
  # from this conversation (personal or same-workspace), so a different
  # workspace's brain can never be reached by name either.
  defp resolve_explicit_brain(value, actor, workspace_id) do
    if uuid?(value) do
      case match_brain_id_in_scope(value, workspace_id) do
        {:ok, id} -> {:ok, id}
        :not_found -> resolve_brain_by_name(value, actor, workspace_id)
        {:error, _} = err -> err
      end
    else
      resolve_brain_by_name(value, actor, workspace_id)
    end
  end

  # Direct id match with the workspace rule: personal brains (workspace_id nil)
  # are reachable from any conversation; a workspace brain is reachable only
  # from a conversation in the same workspace. Returns `:not_found` (rather than
  # an error) when no brain has that id, so the caller can fall back to a
  # slug/title lookup.
  defp match_brain_id_in_scope(brain_id, conv_workspace_id) do
    case Magus.Brain.BrainResource
         |> Ash.Query.filter(id == ^brain_id)
         |> Ash.Query.select([:id, :workspace_id])
         |> Ash.read_one(authorize?: false) do
      {:ok, %{workspace_id: nil}} -> {:ok, brain_id}
      {:ok, %{workspace_id: ^conv_workspace_id}} -> {:ok, brain_id}
      {:ok, %{workspace_id: _other}} -> {:error, different_workspace_error()}
      {:ok, nil} -> :not_found
      {:error, _} -> :not_found
    end
  end

  # Resolve a slug or title against the brains the actor can actually reach from
  # this conversation (authorization + workspace scope applied by the read).
  # Slug is unique per user, so it wins outright; titles can repeat, so a
  # duplicate title yields an actionable ambiguity error listing the ids.
  defp resolve_brain_by_name(value, actor, workspace_id) do
    brains = reachable_brains(actor, workspace_id)

    cond do
      brain = Enum.find(brains, &(&1.slug == value)) ->
        {:ok, brain.id}

      true ->
        case Enum.filter(brains, &title_match?(&1, value)) do
          [brain] -> {:ok, brain.id}
          [] -> {:error, brain_not_found_error(value, brains)}
          many -> {:error, ambiguous_brain_error(value, many)}
        end
    end
  end

  defp reachable_brains(nil, _workspace_id), do: []

  defp reachable_brains(actor, nil) do
    Magus.Brain.BrainResource
    |> Ash.Query.filter(is_nil(workspace_id))
    |> read_reachable(actor)
  end

  defp reachable_brains(actor, workspace_id) do
    Magus.Brain.BrainResource
    |> Ash.Query.filter(workspace_id == ^workspace_id or is_nil(workspace_id))
    |> read_reachable(actor)
  end

  defp read_reachable(query, actor) do
    query
    |> Ash.Query.select([:id, :title, :slug, :workspace_id])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, brains} -> brains
      _ -> []
    end
  end

  defp title_match?(%{title: t}, value) when is_binary(t) and is_binary(value),
    do: String.downcase(t) == String.downcase(value)

  defp title_match?(_, _), do: false

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_), do: false

  defp different_workspace_error do
    "That brain belongs to a different workspace than this conversation. " <>
      "Use read_brain list_brains to pick a brain in the current workspace."
  end

  defp brain_not_found_error(value, brains) do
    "No brain matches \"#{value}\" by id, slug, or title in this workspace." <>
      available_suffix(brains)
  end

  defp ambiguous_brain_error(value, brains) do
    "Multiple brains are titled \"#{value}\". Pass an exact brain_id: " <>
      Enum.map_join(brains, "; ", &"#{&1.title} (brain_id: #{&1.id})")
  end

  defp available_suffix([]), do: ""

  defp available_suffix(brains) do
    " Available: " <> Enum.map_join(brains, "; ", &"#{&1.title} (brain_id: #{&1.id})")
  end

  @doc """
  Resolves a page from params, context, or title lookup.

  Resolution order:
  1. `params["page_id"]` (explicit page ID)
  2. `params["page_title"]` (title lookup within brain)
  3. `context[:brain_page_id]` (active pane context)
  """
  @spec resolve_page(map(), map(), String.t()) ::
          {:ok, Ash.Resource.record()} | {:error, String.t()}
  def resolve_page(context, params, brain_id) do
    actor = get_context_value(context, :user)

    cond do
      page_id = get_param(params, :page_id) ->
        Resolver.resolve_page(actor, brain_id, page_id: page_id)

      page_title = get_param(params, :page_title) ->
        Resolver.resolve_page(actor, brain_id, page_title: page_title)

      page_id = get_context_value(context, :brain_page_id) ->
        Resolver.resolve_page(actor, brain_id, page_id: page_id)

      true ->
        {:error,
         "No page specified. Provide a page_id, page_title, or open a page in the brain pane."}
    end
  end

  @doc """
  Thin wrapper around `resolve_page/3` that returns just the page ID.
  """
  @spec resolve_page_id(map(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_page_id(context, params, brain_id) do
    case resolve_page(context, params, brain_id) do
      {:ok, page} -> {:ok, page.id}
      {:error, _} = error -> error
    end
  end

  @doc """
  Lists all brain ID + title pairs the actor can see, scoped to
  `context[:workspace_id]` when present.
  """
  @spec resolve_brain_ids(map(), Ash.Resource.record()) ::
          {:ok, [{String.t(), String.t()}]}
  def resolve_brain_ids(context, user) do
    workspace_id = get_context_value(context, :workspace_id)
    Resolver.list_brain_summaries(user, workspace_id: workspace_id)
  end
end
