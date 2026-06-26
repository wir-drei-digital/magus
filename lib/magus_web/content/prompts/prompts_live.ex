defmodule MagusWeb.PromptsLive do
  @moduledoc """
  Prompts library page for discovering, managing, and copying prompts.
  """
  use MagusWeb, :live_view

  on_mount {MagusWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    tags = Magus.Library.list_tags!()

    # Default to "mine" if logged in, otherwise "public"
    default_filter = if socket.assigns.current_user, do: :all, else: :public

    socket =
      socket
      |> assign(:page_title, gettext("Prompts Library"))
      |> assign(:search_query, "")
      |> assign(:filter_source, default_filter)
      |> assign(:filter_type, nil)
      |> assign(:filter_tag_ids, [])
      |> assign(:sort_by, :recent)
      |> assign(:tags, tags)
      |> assign(:highlighted_prompts, [])
      |> assign(:show_prompt_form, false)
      |> assign(:editing_prompt, nil)
      |> load_user_favorites()
      |> load_highlighted_items()
      |> load_items()

    {:ok, socket}
  end

  defp load_user_favorites(socket) do
    case socket.assigns.current_user do
      nil ->
        assign(socket, :favorited_prompt_ids, MapSet.new())

      user ->
        prompt_ids =
          Magus.Library.my_prompt_favorites!(actor: user)
          |> Enum.map(& &1.prompt_id)
          |> MapSet.new()

        assign(socket, :favorited_prompt_ids, prompt_ids)
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    socket = assign(socket, :page_title, gettext("Prompts"))

    # Handle legacy edit query param - redirect to new edit view
    case params do
      %{"edit" => prompt_id} ->
        push_navigate(socket, to: ~p"/prompts/#{prompt_id}/edit")

      _ ->
        socket
    end
  end

  defp load_highlighted_items(socket) do
    highlighted_prompts =
      Magus.Library.highlighted_prompts!(authorize?: false, load: [:user, :tags, :model])

    assign(socket, :highlighted_prompts, highlighted_prompts)
  end

  defp load_items(socket) do
    %{
      search_query: query,
      filter_source: source,
      filter_type: type,
      filter_tag_ids: _tag_ids,
      sort_by: _sort_by,
      current_user: current_user
    } = socket.assigns

    prompts =
      case source do
        :mine when current_user != nil ->
          # User's own prompts
          base_prompts =
            Magus.Library.my_prompts!(actor: current_user, load: [:user, :tags, :model])

          filter_prompts(base_prompts, query, type)

        :public ->
          # Only public prompts
          Magus.Library.public_search_prompts!(
            %{query: query, type: type, tag_ids: [], sort_by: :recent},
            authorize?: false,
            load: [:user, :tags, :model]
          )

        :all when current_user != nil ->
          # User's prompts + public prompts (deduplicated)
          my_prompts =
            Magus.Library.my_prompts!(actor: current_user, load: [:user, :tags, :model])

          public_prompts =
            Magus.Library.public_search_prompts!(
              %{query: query, type: type, tag_ids: [], sort_by: :recent},
              authorize?: false,
              load: [:user, :tags, :model]
            )

          # Merge and deduplicate (user's prompts take precedence)
          my_ids = MapSet.new(my_prompts, & &1.id)

          public_prompts_filtered =
            Enum.reject(public_prompts, fn p -> MapSet.member?(my_ids, p.id) end)

          all_prompts = my_prompts ++ public_prompts_filtered
          filter_prompts(all_prompts, query, type)

        _ ->
          # Fallback to public only
          Magus.Library.public_search_prompts!(
            %{query: query, type: type, tag_ids: [], sort_by: :recent},
            authorize?: false,
            load: [:user, :tags, :model]
          )
      end

    stream(socket, :prompts, prompts, reset: true)
  end

  defp filter_prompts(prompts, query, type) do
    prompts
    |> Enum.filter(fn p ->
      matches_query =
        if query && query != "" do
          query_down = String.downcase(query)

          String.contains?(String.downcase(p.name), query_down) ||
            String.contains?(String.downcase(p.content || ""), query_down)
        else
          true
        end

      matches_type = if type, do: p.type == type, else: true

      matches_query && matches_type
    end)
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> load_items()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_source", %{"source" => source}, socket) do
    source_atom = String.to_existing_atom(source)

    socket =
      socket
      |> assign(:filter_source, source_atom)
      |> load_items()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_prompt_type", %{"type" => type}, socket) do
    type_atom =
      case type do
        "" -> nil
        t -> String.to_existing_atom(t)
      end

    socket =
      socket
      |> assign(:filter_type, type_atom)
      |> load_items()

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_tag", %{"tag-id" => tag_id}, socket) do
    current_tags = socket.assigns.filter_tag_ids

    new_tags =
      if tag_id in current_tags do
        List.delete(current_tags, tag_id)
      else
        [tag_id | current_tags]
      end

    socket =
      socket
      |> assign(:filter_tag_ids, new_tags)
      |> load_items()

    {:noreply, socket}
  end

  @impl true
  def handle_event("sort_by", %{"sort" => sort}, socket) do
    sort_atom = String.to_existing_atom(sort)

    socket =
      socket
      |> assign(:sort_by, sort_atom)
      |> load_items()

    {:noreply, socket}
  end

  @impl true
  def handle_event("favorite_prompt", %{"id" => prompt_id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Sign in to favorite items"))}

      user ->
        # Check if already favorited
        case Magus.Library.my_prompt_favorites!(actor: user)
             |> Enum.find(&(&1.prompt_id == prompt_id)) do
          nil ->
            Magus.Library.create_prompt_favorite!(%{prompt_id: prompt_id}, actor: user)

            {:noreply,
             socket
             |> put_flash(:info, gettext("Added to favorites"))
             |> load_user_favorites()
             |> load_highlighted_items()
             |> load_items()}

          favorite ->
            Magus.Library.destroy_prompt_favorite!(favorite, actor: user)

            {:noreply,
             socket
             |> put_flash(:info, gettext("Removed from favorites"))
             |> load_user_favorites()
             |> load_highlighted_items()
             |> load_items()}
        end
    end
  end

  @impl true
  def handle_event("delete_prompt", %{"id" => prompt_id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Sign in to delete prompts"))}

      user ->
        case Magus.Library.get_prompt(prompt_id, actor: user) do
          {:ok, prompt} ->
            if prompt.user_id == user.id do
              Magus.Library.destroy_prompt!(prompt, actor: user)

              {:noreply,
               socket
               |> put_flash(:info, gettext("Prompt deleted"))
               |> push_navigate(to: ~p"/prompts")
               |> load_items()}
            else
              {:noreply,
               put_flash(socket, :error, gettext("You can only delete your own prompts"))}
            end

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Prompt not found"))}
        end
    end
  end

  @impl true
  def handle_event("toggle_publish", %{"id" => prompt_id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Sign in to publish prompts"))}

      user ->
        case Magus.Library.get_prompt(prompt_id, actor: user) do
          {:ok, prompt} ->
            if prompt.user_id == user.id do
              if prompt.is_public do
                Magus.Library.unpublish_prompt!(prompt, actor: user)

                {:noreply,
                 socket
                 |> put_flash(:info, gettext("Prompt unpublished"))
                 |> load_highlighted_items()
                 |> load_items()}
              else
                Magus.Library.publish_prompt!(prompt, %{is_public: true}, actor: user)

                {:noreply,
                 socket
                 |> put_flash(:info, gettext("Prompt published"))
                 |> load_highlighted_items()
                 |> load_items()}
              end
            else
              {:noreply,
               put_flash(socket, :error, gettext("You can only publish your own prompts"))}
            end

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Prompt not found"))}
        end
    end
  end

  @impl true
  def handle_event("edit_prompt", %{"id" => prompt_id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Sign in to edit prompts"))}

      user ->
        case Magus.Library.get_prompt(prompt_id, actor: user) do
          {:ok, prompt} ->
            if prompt.user_id == user.id do
              {:noreply,
               socket
               |> assign(:show_prompt_form, true)
               |> assign(:editing_prompt, prompt)}
            else
              {:noreply, put_flash(socket, :error, gettext("You can only edit your own prompts"))}
            end

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Prompt not found"))}
        end
    end
  end

  # Handle messages from PromptFormModalComponent
  @impl true
  def handle_info(
        {MagusWeb.ChatLive.Components.PromptFormModalComponent, {:prompt_saved, _prompt}},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:show_prompt_form, false)
     |> assign(:editing_prompt, nil)
     |> put_flash(:info, gettext("Prompt updated successfully"))
     |> load_highlighted_items()
     |> load_items()}
  end

  @impl true
  def handle_info({MagusWeb.ChatLive.Components.PromptFormModalComponent, :modal_closed}, socket) do
    {:noreply,
     socket
     |> assign(:show_prompt_form, false)
     |> assign(:editing_prompt, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.content
      flash={@flash}
      current_user={@current_user}
      base_path="/prompts"
    >
      <%!-- Edit Prompt Modal --%>
      <.live_component
        :if={@current_user}
        module={MagusWeb.ChatLive.Components.PromptFormModalComponent}
        id="prompt-form-modal"
        show={@show_prompt_form}
        prompt={@editing_prompt}
        current_user={@current_user}
      />

      <div class="container mx-auto px-4 py-6 max-w-7xl">
        <%!-- Header --%>
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 mb-6">
          <div>
            <h1 class="text-2xl font-bold text-base-content">{gettext("Prompts Library")}</h1>
            <p class="text-base-content/60 text-sm mt-1">
              {gettext("Discover and copy shared prompts")}
            </p>
          </div>

          <%!-- Search --%>
          <form phx-change="search" phx-submit="search" class="flex-1 max-w-md">
            <.search_input
              value={@search_query}
              placeholder={gettext("Search prompts...")}
            />
          </form>
        </div>

        <%!-- Highlighted Section --%>
        <%= if @highlighted_prompts != [] do %>
          <div class="mb-8">
            <h2 class="text-lg font-semibold text-base-content mb-4 flex items-center gap-2">
              <.icon name="lucide-star" class="w-5 h-5 text-warning" /> {gettext("Featured")}
            </h2>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              <%= for prompt <- @highlighted_prompts do %>
                <.prompt_card
                  prompt={prompt}
                  highlighted={true}
                  current_user={@current_user}
                  is_favorited={MapSet.member?(@favorited_prompt_ids, prompt.id)}
                />
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Filters Bar --%>
        <div class="flex flex-wrap items-center gap-3 mb-6">
          <%!-- Source Filter --%>
          <div class="flex items-center gap-1">
            <button
              :if={@current_user}
              type="button"
              phx-click="filter_source"
              phx-value-source="all"
              class={"btn btn-sm #{if @filter_source == :all, do: "btn-primary", else: "btn-ghost"}"}
            >
              {gettext("All")}
            </button>
            <button
              type="button"
              phx-click="filter_source"
              phx-value-source="public"
              class={"btn btn-sm #{if @filter_source == :public, do: "btn-primary", else: "btn-ghost"}"}
            >
              {gettext("Public")}
            </button>
            <button
              :if={@current_user}
              type="button"
              phx-click="filter_source"
              phx-value-source="mine"
              class={"btn btn-sm #{if @filter_source == :mine, do: "btn-primary", else: "btn-ghost"}"}
            >
              {gettext("My Prompts")}
            </button>
          </div>

          <div class="w-px h-6 bg-base-300 mx-1"></div>

          <%!-- Prompt Type Filter --%>
          <form phx-change="filter_prompt_type" class="flex items-center gap-2">
            <span class="text-sm text-base-content/60">{gettext("Type:")}</span>
            <select class="select select-sm select-bordered" name="type">
              <option value="">{gettext("All Types")}</option>
              <option value="system" selected={@filter_type == :system}>
                {gettext("System")}
              </option>
              <option value="user" selected={@filter_type == :user}>
                {gettext("User")}
              </option>
            </select>
          </form>

          <%!-- Sort By --%>
          <form phx-change="sort_by" class="flex items-center gap-2 ml-auto">
            <span class="text-sm text-base-content/60">{gettext("Sort:")}</span>
            <select class="select select-sm select-bordered" name="sort">
              <option value="recent" selected={@sort_by == :recent}>{gettext("Recent")}</option>
              <option value="popular" selected={@sort_by == :popular}>{gettext("Popular")}</option>
              <option value="name" selected={@sort_by == :name}>{gettext("Name")}</option>
            </select>
          </form>
        </div>

        <%!-- Tags Filter --%>
        <%= if @tags != [] do %>
          <div class="flex flex-wrap gap-2 mb-6">
            <%= for tag <- @tags do %>
              <button
                type="button"
                phx-click="toggle_tag"
                phx-value-tag-id={tag.id}
                class={"content-tag cursor-pointer #{if tag.id in @filter_tag_ids, do: "content-tag-selected"}"}
              >
                #{tag.name}
              </button>
            <% end %>
          </div>
        <% end %>

        <%!-- Results --%>
        <div
          id="prompts"
          phx-update="stream"
          class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
        >
          <div :for={{id, prompt} <- @streams.prompts} id={id} class="h-full">
            <.prompt_card
              prompt={prompt}
              current_user={@current_user}
              is_favorited={MapSet.member?(@favorited_prompt_ids, prompt.id)}
            />
          </div>
        </div>
      </div>
    </Layouts.content>
    """
  end

  # Prompt Card Component
  attr :prompt, :map, required: true
  attr :highlighted, :boolean, default: false
  attr :current_user, :map, default: nil
  attr :is_favorited, :boolean, default: false

  defp prompt_card(assigns) do
    is_owner = assigns.current_user && assigns.prompt.user_id == assigns.current_user.id
    assigns = assign(assigns, :is_owner, is_owner)

    ~H"""
    <div class={"library-card relative h-full flex flex-col #{if @highlighted, do: "ring-2 ring-warning"}"}>
      <.link
        navigate={~p"/prompts/#{@prompt.id}"}
        class="flex-1 flex flex-col cursor-pointer hover:bg-base-200/50 transition-colors"
      >
        <div class="p-4 flex-1 flex flex-col">
          <%!-- Header --%>
          <div class="flex items-start justify-between gap-2">
            <div class="flex items-center gap-2 flex-wrap">
              <%= if @highlighted do %>
                <.icon name="lucide-star" class="w-4 h-4 text-warning" />
              <% end %>
              <span class={"type-tag #{prompt_type_class(@prompt.type)}"}>
                {prompt_type_label(@prompt.type)}
              </span>
              <%= if @prompt.type == :system && @prompt.chat_mode do %>
                <span class="type-tag type-tag-user text-xs">
                  {Phoenix.Naming.humanize(@prompt.chat_mode)}
                </span>
              <% end %>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <%!-- Visibility icon --%>
              <%= if @prompt.is_public do %>
                <span title={gettext("Public")}>
                  <.icon name="lucide-globe" class="w-4 h-4 text-success" />
                </span>
              <% else %>
                <span title={gettext("Private")}>
                  <.icon name="lucide-lock" class="w-4 h-4 text-base-content/40" />
                </span>
              <% end %>
              <div class="flex items-center gap-1 text-xs text-base-content/50">
                <.icon name="lucide-files" class="w-3 h-3" />
                {@prompt.copy_count}
              </div>
            </div>
          </div>

          <%!-- Title --%>
          <h3 class="font-semibold text-base-content line-clamp-1 mt-2">{@prompt.name}</h3>

          <%!-- Author --%>
          <p class="text-xs text-base-content/50">
            <%= if @is_owner do %>
              <span class="text-primary">{gettext("You")}</span>
            <% else %>
              by {@prompt.user &&
                @prompt.user.email |> to_string() |> String.split("@") |> List.first()}
            <% end %>
          </p>

          <%!-- Model Badge for system prompts --%>
          <%= if @prompt.type == :system && @prompt.model do %>
            <div class="flex items-center gap-1 mt-1">
              <span class="badge badge-sm badge-outline">
                <.icon name="lucide-cpu" class="w-3 h-3 mr-1" /> {@prompt.model.name}
              </span>
            </div>
          <% end %>

          <%!-- Content Preview --%>
          <p class="text-sm text-base-content/70 line-clamp-3 mt-2 flex-1">{@prompt.content}</p>

          <%!-- Tags --%>
          <%= if @prompt.tags && @prompt.tags != [] do %>
            <div class="flex flex-wrap gap-1 mt-2">
              <%= for tag <- Enum.take(@prompt.tags, 3) do %>
                <span class="content-tag">#{tag.name}</span>
              <% end %>
              <%= if length(@prompt.tags) > 3 do %>
                <span class="content-tag">+{length(@prompt.tags) - 3}</span>
              <% end %>
            </div>
          <% end %>
        </div>
      </.link>

      <%!-- Context Menu (only for owner) --%>
      <div :if={@is_owner} class="absolute bottom-2 right-2">
        <details class="dropdown dropdown-top dropdown-end">
          <summary class="btn btn-ghost btn-xs btn-circle">
            <.icon name="lucide-more-vertical" class="w-4 h-4" />
          </summary>
          <ul class="dropdown-content z-[1] menu p-2 bg-base-100 border border-base-300 rounded-lg shadow-xl w-40">
            <li>
              <span
                phx-click="edit_prompt"
                phx-value-id={@prompt.id}
                onclick="this.closest('details').removeAttribute('open')"
                class="flex items-center gap-2 text-sm cursor-pointer"
              >
                <.icon name="lucide-pencil" class="w-4 h-4" />
                {gettext("Edit")}
              </span>
            </li>
            <li>
              <span
                phx-click="toggle_publish"
                phx-value-id={@prompt.id}
                onclick="this.closest('details').removeAttribute('open')"
                class="flex items-center gap-2 text-sm cursor-pointer"
              >
                <.icon
                  name={if @prompt.is_public, do: "lucide-eye-off", else: "lucide-eye"}
                  class="w-4 h-4"
                />
                {if @prompt.is_public, do: gettext("Unpublish"), else: gettext("Publish")}
              </span>
            </li>
            <li>
              <span
                phx-click="delete_prompt"
                phx-value-id={@prompt.id}
                onclick="this.closest('details').removeAttribute('open')"
                data-confirm={gettext("Are you sure you want to delete this prompt?")}
                class="flex items-center gap-2 text-sm cursor-pointer text-error"
              >
                <.icon name="lucide-trash-2" class="w-4 h-4" />
                {gettext("Delete")}
              </span>
            </li>
          </ul>
        </details>
      </div>
    </div>
    """
  end

  defp prompt_type_label(:system), do: gettext("System")
  defp prompt_type_label(:user), do: gettext("User")
  defp prompt_type_label(_), do: gettext("Prompt")

  defp prompt_type_class(:system), do: "type-tag-system"
  defp prompt_type_class(:user), do: "type-tag-user"
  defp prompt_type_class(_), do: "type-tag-user"
end
