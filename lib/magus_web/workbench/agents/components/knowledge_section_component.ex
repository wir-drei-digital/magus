defmodule MagusWeb.AgentsLive.Components.KnowledgeSectionComponent do
  @moduledoc """
  LiveComponent for managing agent-scoped memories (knowledge) within the agent form.

  Provides list, add, and detail views for CRUD operations on Memory resources
  scoped to a custom agent.
  """

  use MagusWeb, :live_component

  @kind_options [
    {"General", "general"},
    {"Fact", "fact"},
    {"Hypothesis", "hypothesis"},
    {"Observation", "observation"},
    {"Summary", "summary"},
    {"Preference", "preference"}
  ]

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       view: :list,
       memories: [],
       selected_memory: nil,
       associations: [],
       form: nil,
       kind_options: @kind_options,
       knowledge_sources: [],
       granted_collection_ids: [],
       can_access_knowledge: true,
       available_brains: [],
       granted_brain_ids: []
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if assigns[:custom_agent_id] && socket.assigns.view == :list do
        socket
        |> load_memories()
        |> load_knowledge_collections()
        |> load_brain_access()
      else
        socket
      end

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <%= case @view do %>
        <% :list -> %>
          {render_memory_card(assigns)}
          {render_brain_access_card(assigns)}
          {render_knowledge_collections_card(assigns)}
        <% :detail -> %>
          {render_detail(assigns)}
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Agent Memory Card
  # ---------------------------------------------------------------------------

  defp render_memory_card(assigns) do
    ~H"""
    <.content_card
      title={gettext("Memory")}
      icon="lucide-book-open"
      subtitle={
        gettext(
          "Memories the agent builds up over time through conversations. You can view, edit, or remove individual entries."
        )
      }
    >
      <div :if={@memories == []} class="py-6 text-center">
        <p class="text-sm text-base-content/50">
          {gettext(
            "No memories yet. The agent will create memories automatically during conversations."
          )}
        </p>
      </div>

      <div :if={@memories != []} class="space-y-2">
        <div
          :for={memory <- @memories}
          class="flex items-start justify-between gap-2 p-3 rounded-lg bg-base-300/50 cursor-pointer hover:bg-base-300 transition-colors"
          phx-click="select_memory"
          phx-value-id={memory.id}
          phx-target={@myself}
        >
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <span class="font-medium text-sm">{memory.name}</span>
              <span :if={memory.kind != :general} class="badge badge-xs badge-outline">
                {memory.kind}
              </span>
              <span :if={memory.confidence < 1.0} class="badge badge-xs badge-ghost">
                {format_confidence(memory.confidence)}
              </span>
            </div>
            <p :if={memory.summary} class="text-xs text-base-content/60 mt-1 truncate">
              {memory.summary}
            </p>
          </div>
          <.icon name="lucide-chevron-right" class="w-4 h-4 text-base-content/40 shrink-0 mt-0.5" />
        </div>
      </div>
    </.content_card>
    """
  end

  # ---------------------------------------------------------------------------
  # Brain Access Card
  # ---------------------------------------------------------------------------

  defp render_brain_access_card(assigns) do
    ~H"""
    <.content_card
      title={gettext("Brain Access")}
      icon="lucide-brain"
      subtitle={gettext("Select which brains this agent can read and edit autonomously.")}
    >
      <div class="space-y-2">
        <div
          :for={brain <- @available_brains}
          class="flex items-center gap-3 cursor-pointer p-2.5 rounded-lg hover:bg-base-300/50 transition-colors"
          phx-click="toggle_brain_access"
          phx-value-brain-id={brain.id}
          phx-target={@myself}
        >
          <input
            type="checkbox"
            checked={brain.id in @granted_brain_ids}
            class="checkbox checkbox-sm checkbox-primary pointer-events-none"
          />
          <div class="flex items-center gap-2 flex-1 min-w-0">
            <span :if={brain.icon} class="text-base shrink-0">{brain.icon}</span>
            <.icon :if={!brain.icon} name="lucide-brain" class="w-4 h-4 shrink-0 text-primary" />
            <span class="text-sm truncate">{brain.title}</span>
          </div>
          <span :if={brain.id in @granted_brain_ids} class="badge badge-xs badge-primary">
            {gettext("editor")}
          </span>
        </div>

        <div :if={@available_brains == []} class="py-6 text-center">
          <p class="text-sm text-base-content/50">{gettext("No brains created yet.")}</p>
          <p class="text-xs text-base-content/40 mt-1">
            {gettext("Create a brain from the Brains tab in the chat sidebar.")}
          </p>
        </div>
      </div>
    </.content_card>
    """
  end

  # ---------------------------------------------------------------------------
  # Knowledge Collections Card
  # ---------------------------------------------------------------------------

  defp render_knowledge_collections_card(assigns) do
    ~H"""
    <.content_card
      title={gettext("Collections")}
      icon="lucide-library"
      subtitle={gettext("Select which collections this agent can search.")}
    >
      <div class="flex items-center justify-end mb-3">
        <div
          class="flex items-center gap-2 cursor-pointer"
          phx-click="toggle_knowledge_access"
          phx-target={@myself}
        >
          <span class="text-xs text-base-content/60">{gettext("Enabled")}</span>
          <input type="hidden" name="knowledge_access" value="false" />
          <input
            type="checkbox"
            name="knowledge_access"
            id="knowledge_access"
            value="true"
            checked={@can_access_knowledge}
            class="toggle toggle-primary toggle-sm pointer-events-none"
          />
        </div>
      </div>

      <div :if={@can_access_knowledge} class="space-y-4">
        <div :for={source_group <- @knowledge_sources} class="space-y-1">
          <div class="text-xs text-base-content/50 uppercase tracking-wider mb-2">
            {source_group.source.name}
          </div>
          <div
            :for={collection <- source_group.collections}
            class="flex items-center gap-2 cursor-pointer p-2.5 rounded-lg hover:bg-base-300/50 transition-colors"
            phx-click="toggle_collection_grant"
            phx-value-id={collection.id}
            phx-target={@myself}
          >
            <input type="hidden" name={"collection_grant_#{collection.id}"} value="false" />
            <input
              type="checkbox"
              name={"collection_grant_#{collection.id}"}
              id={"collection_grant_#{collection.id}"}
              value="true"
              checked={collection.id in @granted_collection_ids}
              class="checkbox checkbox-sm checkbox-primary pointer-events-none"
            />
            <div class="flex-1 min-w-0">
              <span class="text-sm">{collection.name}</span>
              <span class="text-xs text-base-content/40 ml-2">
                {ngettext("%{count} file", "%{count} files", collection.item_count || 0)}
              </span>
            </div>
          </div>
        </div>

        <div :if={@knowledge_sources == []} class="py-6 text-center">
          <p class="text-sm text-base-content/50">{gettext("No knowledge sources connected.")}</p>
          <.link navigate="/settings/knowledge" class="text-sm text-primary hover:underline mt-1">
            {gettext("Connect sources in Settings")}
          </.link>
        </div>
      </div>
    </.content_card>
    """
  end

  # ---------------------------------------------------------------------------
  # Detail View
  # ---------------------------------------------------------------------------

  defp render_detail(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center gap-2">
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="back_to_list"
          phx-target={@myself}
        >
          <.icon name="lucide-arrow-left" class="w-4 h-4" />
        </button>
        <h3 class="text-lg font-medium">{@selected_memory.name}</h3>
        <span
          :if={@selected_memory.kind != :general}
          class="badge badge-sm badge-outline"
        >
          {@selected_memory.kind}
        </span>
      </div>

      <.form for={@form} phx-submit="update_memory" phx-target={@myself} class="space-y-4">
        <div class="form-control">
          <label class="label">
            <span class="label-text">{gettext("Summary")}</span>
          </label>
          <textarea
            name="memory[summary]"
            class="textarea textarea-bordered w-full"
            rows="4"
          >{@form[:summary].value}</textarea>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text">{gettext("Kind")}</span>
          </label>
          <select name="memory[kind]" class="select select-bordered w-full">
            <option
              :for={{label, value} <- @kind_options}
              value={value}
              selected={to_string(@form[:kind].value) == value}
            >
              {label}
            </option>
          </select>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text">
              {gettext("Confidence")}: {format_slider_confidence(@form[:confidence].value)}
            </span>
          </label>
          <input
            type="range"
            name="memory[confidence]"
            min="0"
            max="100"
            value={@form[:confidence].value || 100}
            class="range range-primary range-sm"
          />
        </div>

        <div class="flex items-center justify-end gap-2">
          <button type="submit" class="btn btn-primary btn-sm">
            {gettext("Save Changes")}
          </button>
        </div>
      </.form>

      <%!-- Associated Memories --%>
      <div :if={@associations != []} class="space-y-2 pt-2">
        <h4 class="text-sm font-medium text-base-content/70">{gettext("Associated Memories")}</h4>
        <div
          :for={assoc <- @associations}
          class="flex items-center justify-between p-3 bg-base-200 rounded-lg"
        >
          <div class="min-w-0 flex-1">
            <p class="text-sm font-medium truncate">
              {linked_memory_name(assoc, @selected_memory.id)}
            </p>
            <p
              :if={linked_memory_summary(assoc, @selected_memory.id)}
              class="text-xs text-base-content/60 truncate"
            >
              {linked_memory_summary(assoc, @selected_memory.id)}
            </p>
          </div>
          <span class="badge badge-sm badge-ghost ml-2 shrink-0">
            {format_confidence(assoc.weight)}
          </span>
        </div>
      </div>

      <%!-- Delete Button --%>
      <div class="pt-4 border-t border-base-300">
        <button
          type="button"
          class="btn btn-error btn-sm btn-outline"
          phx-click="delete_memory"
          phx-target={@myself}
          data-confirm={gettext("Are you sure you want to delete this memory?")}
        >
          <.icon name="lucide-trash-2" class="w-4 h-4" />
          {gettext("Delete")}
        </button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Event Handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("back_to_list", _params, socket) do
    socket =
      socket
      |> assign(view: :list, selected_memory: nil, associations: [], form: nil)
      |> load_memories()

    {:noreply, socket}
  end

  def handle_event("select_memory", %{"id" => id}, socket) do
    case Magus.Memory.get_memory(id, actor: current_user(socket)) do
      {:ok, memory} ->
        associations = load_associations(memory.id, socket)

        form =
          to_form(
            %{
              "summary" => memory.summary || "",
              "kind" => to_string(memory.kind),
              "confidence" => round(memory.confidence * 100)
            },
            as: "memory"
          )

        {:noreply,
         assign(socket,
           view: :detail,
           selected_memory: memory,
           associations: associations,
           form: form
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Memory not found."))}
    end
  end

  def handle_event("update_memory", %{"memory" => params}, socket) do
    memory = socket.assigns.selected_memory

    attrs = %{
      summary: blank_to_nil(params["summary"]),
      kind: safe_to_kind_atom(params["kind"]),
      confidence: parse_confidence(params["confidence"])
    }

    case Magus.Memory.set_memory(memory, memory.content || %{}, attrs,
           actor: current_user(socket)
         ) do
      {:ok, updated} ->
        form =
          to_form(
            %{
              "summary" => updated.summary || "",
              "kind" => to_string(updated.kind),
              "confidence" => round(updated.confidence * 100)
            },
            as: "memory"
          )

        {:noreply,
         socket
         |> assign(selected_memory: updated, form: form)
         |> put_flash(:info, gettext("Memory updated."))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update memory."))}
    end
  end

  def handle_event("delete_memory", _params, socket) do
    memory = socket.assigns.selected_memory

    case Magus.Memory.destroy_memory(memory, actor: current_user(socket)) do
      :ok ->
        socket =
          socket
          |> assign(view: :list, selected_memory: nil, associations: [], form: nil)
          |> load_memories()
          |> put_flash(:info, gettext("Memory deleted."))

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete memory."))}
    end
  end

  def handle_event("toggle_knowledge_access", _params, socket) do
    new_value = !socket.assigns.can_access_knowledge
    agent_id = socket.assigns.custom_agent_id
    user = current_user(socket)

    if agent_id do
      case Magus.Agents.get_custom_agent(agent_id, actor: user) do
        {:ok, agent} ->
          Magus.Agents.update_custom_agent(agent, %{can_access_knowledge: new_value}, actor: user)

        _ ->
          :ok
      end
    end

    {:noreply, assign(socket, :can_access_knowledge, new_value)}
  end

  def handle_event("toggle_collection_grant", %{"id" => collection_id}, socket) do
    agent_id = socket.assigns.custom_agent_id
    granted = socket.assigns.granted_collection_ids
    user = current_user(socket)

    if collection_id in granted do
      result =
        case Magus.Workspaces.list_access_for_resource(:knowledge_collection, collection_id,
               actor: user
             ) do
          {:ok, grants} ->
            grant =
              Enum.find(
                grants,
                &(&1.grantee_type == :custom_agent && &1.grantee_id == agent_id)
              )

            if grant, do: Magus.Workspaces.revoke_access(grant, actor: user), else: :ok

          _ ->
            {:error, :not_found}
        end

      case result do
        :ok ->
          {:noreply, assign(socket, :granted_collection_ids, List.delete(granted, collection_id))}

        {:ok, _} ->
          {:noreply, assign(socket, :granted_collection_ids, List.delete(granted, collection_id))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to revoke access"))}
      end
    else
      case Magus.Workspaces.grant_access(
             %{
               resource_type: :knowledge_collection,
               resource_id: collection_id,
               grantee_type: :custom_agent,
               grantee_id: agent_id,
               role: :editor
             },
             actor: user
           ) do
        {:ok, _} ->
          {:noreply, assign(socket, :granted_collection_ids, [collection_id | granted])}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to grant access"))}
      end
    end
  end

  def handle_event("toggle_brain_access", %{"brain-id" => brain_id}, socket) do
    agent_id = socket.assigns.custom_agent_id
    granted = socket.assigns.granted_brain_ids
    user = current_user(socket)

    if brain_id in granted do
      # Revoke: find and destroy the ResourceAccess grant
      case Magus.Workspaces.list_access_for_resource(:brain, brain_id, actor: user) do
        {:ok, grants} ->
          grant =
            Enum.find(grants, fn g ->
              g.grantee_type == :custom_agent && g.grantee_id == agent_id
            end)

          if grant do
            Magus.Workspaces.revoke_access(grant, actor: user)
          end

          {:noreply, assign(socket, :granted_brain_ids, List.delete(granted, brain_id))}

        _ ->
          {:noreply, put_flash(socket, :error, gettext("Failed to revoke brain access"))}
      end
    else
      # Grant editor access
      case Magus.Workspaces.grant_access(
             %{
               resource_type: :brain,
               resource_id: brain_id,
               grantee_type: :custom_agent,
               grantee_id: agent_id,
               role: :editor
             },
             actor: user
           ) do
        {:ok, _} ->
          {:noreply, assign(socket, :granted_brain_ids, [brain_id | granted])}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to grant brain access"))}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_memories(socket) do
    case Magus.Memory.list_agent_memories(socket.assigns.custom_agent_id,
           actor: current_user(socket)
         ) do
      {:ok, memories} -> assign(socket, :memories, memories)
      {:error, _} -> assign(socket, :memories, [])
    end
  end

  defp load_brain_access(socket) do
    user = current_user(socket)
    agent_id = socket.assigns.custom_agent_id

    # Load all brains owned by this user
    available_brains = Magus.Brain.list_brains!(actor: user)

    # Load existing ResourceAccess grants for this agent
    granted_brain_ids =
      available_brains
      |> Enum.filter(fn brain ->
        case Magus.Workspaces.list_access_for_resource(:brain, brain.id, actor: user) do
          {:ok, grants} ->
            Enum.any?(grants, fn g ->
              g.grantee_type == :custom_agent && g.grantee_id == agent_id
            end)

          _ ->
            false
        end
      end)
      |> Enum.map(& &1.id)

    assign(socket,
      available_brains: available_brains,
      granted_brain_ids: granted_brain_ids
    )
  end

  defp load_knowledge_collections(socket) do
    user = current_user(socket)
    agent_id = socket.assigns.custom_agent_id

    # Load the agent's can_access_knowledge flag
    can_access =
      case Magus.Agents.get_custom_agent(agent_id, actor: user) do
        {:ok, agent} -> agent.can_access_knowledge
        _ -> true
      end

    # Load user's knowledge sources and their collections
    sources =
      case Magus.Knowledge.list_sources_for_user(actor: user) do
        {:ok, sources} -> sources
        _ -> []
      end

    knowledge_sources =
      sources
      |> Enum.map(fn source ->
        collections =
          case Magus.Knowledge.list_collections_for_source(source.id, actor: user) do
            {:ok, collections} -> collections
            _ -> []
          end

        %{source: source, collections: collections}
      end)
      |> Enum.reject(fn %{collections: collections} -> collections == [] end)

    # Load existing grants for this agent
    granted_ids = granted_collection_ids(knowledge_sources, agent_id, user)

    assign(socket,
      knowledge_sources: knowledge_sources,
      granted_collection_ids: granted_ids,
      can_access_knowledge: can_access
    )
  end

  defp load_associations(memory_id, socket) do
    case Magus.Memory.get_associations_for_memory(memory_id,
           load: [:memory_a, :memory_b],
           actor: current_user(socket)
         ) do
      {:ok, assocs} -> assocs
      {:error, _} -> []
    end
  end

  defp current_user(socket) do
    # The parent passes user_id; we need the actor struct for authorization.
    # Convention: parent also passes current_user or we look it up.
    # For simplicity, use the assigns if available.
    socket.assigns[:current_user]
  end

  defp granted_collection_ids(knowledge_sources, agent_id, user) do
    knowledge_sources
    |> Enum.flat_map(fn %{collections: collections} -> collections end)
    |> Enum.reduce([], fn collection, acc ->
      case Magus.Workspaces.list_access_for_resource(:knowledge_collection, collection.id,
             actor: user
           ) do
        {:ok, grants} ->
          if Enum.any?(grants, &(&1.grantee_type == :custom_agent && &1.grantee_id == agent_id)) do
            [collection.id | acc]
          else
            acc
          end

        _ ->
          acc
      end
    end)
    |> Enum.uniq()
  end

  defp format_confidence(value) when is_float(value), do: "#{round(value * 100)}%"
  defp format_confidence(value) when is_integer(value), do: "#{value}%"
  defp format_confidence(_), do: "100%"

  defp format_slider_confidence(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> "#{n}%"
      :error -> "100%"
    end
  end

  defp format_slider_confidence(val) when is_integer(val), do: "#{val}%"
  defp format_slider_confidence(_), do: "100%"

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  @valid_kind_strings Enum.map(@kind_options, fn {_, v} -> v end)

  defp safe_to_kind_atom(kind) when kind in @valid_kind_strings,
    do: String.to_existing_atom(kind)

  defp safe_to_kind_atom(_), do: :general

  defp parse_confidence(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> max(0, min(100, n)) / 100
      :error -> 1.0
    end
  end

  defp parse_confidence(val) when is_integer(val), do: max(0, min(100, val)) / 100
  defp parse_confidence(_), do: 1.0

  defp linked_memory_name(assoc, current_id) do
    if assoc.memory_a_id == current_id do
      assoc.memory_b.name
    else
      assoc.memory_a.name
    end
  end

  defp linked_memory_summary(assoc, current_id) do
    if assoc.memory_a_id == current_id do
      assoc.memory_b.summary
    else
      assoc.memory_a.summary
    end
  end
end
