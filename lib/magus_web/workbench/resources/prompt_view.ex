defmodule MagusWeb.Workbench.Resources.PromptView do
  @moduledoc """
  Prompt detail / edit view rendered in the workbench shell's main area
  when the user is in Prompts mode and has selected a prompt.

  Session:
    - `"prompt_id"` — UUID of the prompt
    - `"user_id"` — UUID of the current user
    - `"edit"` — `"true"` to start in edit mode (optional)

  This is always a nested (child) LiveView — it cannot use handle_params.
  Edit state is driven by:
    1. Session on initial mount (from WorkbenchLive passing URL params)
    2. PubSub broadcast {:set_edit_state, edit?} when URL params change while
       the tab is already open
    3. Internal phx-click "enter_edit" / "exit_edit" events
  """
  use MagusWeb, :live_view

  alias AshPhoenix.Form
  alias Magus.Library
  alias MagusWeb.Workbench.WorkspaceShare

  import MagusWeb.Workbench.Components.WorkspaceShareButton

  @prompt_types [:system, :user]

  @impl true
  def mount(_params, session, socket) do
    prompt_id = session["prompt_id"]
    user_id = session["user_id"]
    edit? = session["edit"] == "true"
    tab_id = session["tab_id"]

    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    cond do
      prompt_id == "new" ->
        mount_create(socket, user, tab_id)

      true ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Magus.PubSub, "prompt-view:#{prompt_id}")
        end

        mount_existing(socket, user, prompt_id, edit?, tab_id)
    end
  end

  defp mount_create(socket, user, tab_id) do
    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:prompt, nil)
      |> assign(:prompt_id, "new")
      |> assign(:tab_id, tab_id)
      |> assign(:not_found, false)
      |> assign(:create_mode?, true)
      |> assign(:edit?, false)
      |> assign(:prompt_types, @prompt_types)
      |> assign(:current_type, :user)
      |> load_form_data()
      |> assign_create_form()

    {:ok, socket}
  end

  defp mount_existing(socket, user, prompt_id, edit?, tab_id) do
    case Library.get_prompt(prompt_id,
           actor: user,
           load: [:tags, :model, :is_shared_to_workspace]
         ) do
      {:ok, prompt} ->
        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:prompt, prompt)
          |> assign(:prompt_id, prompt_id)
          |> assign(:tab_id, tab_id)
          |> assign(:not_found, false)
          |> assign(:create_mode?, false)
          |> assign(:edit?, edit?)
          |> assign(:prompt_types, @prompt_types)
          |> assign(:current_type, prompt.type || :user)

        socket =
          if edit? do
            socket
            |> load_form_data()
            |> assign_form(prompt)
          else
            socket
            |> assign(:form, nil)
            |> assign(:available_tags, [])
            |> assign(:selected_tag_ids, [])
            |> assign(:model_options, [])
            |> assign(:chat_mode_options, [])
            |> assign(:language_options, [])
            |> assign(:models, [])
          end

        {:ok, socket}

      _ ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:prompt, nil)
         |> assign(:prompt_id, prompt_id)
         |> assign(:tab_id, tab_id)
         |> assign(:not_found, true)
         |> assign(:create_mode?, false)
         |> assign(:edit?, false)
         |> assign(:prompt_types, @prompt_types)
         |> assign(:current_type, :user)
         |> assign(:form, nil)
         |> assign(:available_tags, [])
         |> assign(:selected_tag_ids, [])
         |> assign(:model_options, [])
         |> assign(:chat_mode_options, [])
         |> assign(:language_options, [])
         |> assign(:models, [])}
    end
  end

  defp load_form_data(socket) do
    available_tags = Library.list_tags!()
    models = Magus.Chat.list_active_models!()
    prompt = socket.assigns.prompt
    selected_tag_ids = if prompt, do: Enum.map(prompt.tags || [], & &1.id), else: []

    model_options =
      [{"None (use conversation default)", nil}] ++
        Enum.map(models, &{&1.name, &1.id})

    chat_mode_options = [
      {gettext("None"), nil},
      {gettext("Chat"), :chat},
      {gettext("Search"), :search},
      {gettext("Image Generation"), :image_generation},
      {gettext("Video Generation"), :video_generation}
    ]

    language_options = [
      {gettext("English"), :en},
      {gettext("German"), :de},
      {gettext("Spanish"), :es},
      {gettext("French"), :fr},
      {gettext("Chinese"), :zh},
      {gettext("Japanese"), :ja},
      {gettext("Korean"), :ko},
      {gettext("Portuguese"), :pt},
      {gettext("Russian"), :ru},
      {gettext("Arabic"), :ar}
    ]

    socket
    |> assign(:available_tags, available_tags)
    |> assign(:selected_tag_ids, selected_tag_ids)
    |> assign(:models, models)
    |> assign(:model_options, model_options)
    |> assign(:chat_mode_options, chat_mode_options)
    |> assign(:language_options, language_options)
  end

  defp assign_form(socket, prompt) do
    form = Form.for_update(prompt, :update, actor: socket.assigns.current_user)
    assign(socket, :form, to_form(form))
  end

  defp assign_create_form(socket) do
    form =
      Form.for_create(Magus.Library.Prompt, :create,
        actor: socket.assigns.current_user,
        params: %{"type" => "user"}
      )

    socket
    |> assign(:form, to_form(form))
    |> assign(:selected_tag_ids, [])
  end

  @impl true
  def handle_event("enter_edit", _params, socket) do
    if socket.assigns.not_found do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:edit?, true)
        |> load_form_data()
        |> assign_form(socket.assigns.prompt)

      {:noreply, socket}
    end
  end

  def handle_event("exit_edit", _params, socket) do
    {:noreply, assign(socket, :edit?, false)}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = Form.validate(socket.assigns.form.source, params)

    current_type =
      case params["type"] do
        "system" -> :system
        "user" -> :user
        _ -> socket.assigns.current_type
      end

    {:noreply,
     socket
     |> assign(:form, to_form(form))
     |> assign(:current_type, current_type)}
  end

  def handle_event("toggle_tag", %{"tag-id" => tag_id}, socket) do
    current = socket.assigns.selected_tag_ids
    new_tags = if tag_id in current, do: List.delete(current, tag_id), else: [tag_id | current]
    {:noreply, assign(socket, :selected_tag_ids, new_tags)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    params =
      if socket.assigns.create_mode? do
        case socket.assigns.current_user.current_workspace_id do
          nil -> params
          ws_id -> Map.put(params, "workspace_id", ws_id)
        end
      else
        params
      end

    case Form.submit(socket.assigns.form.source, params: params) do
      {:ok, prompt} ->
        update_prompt_tags(
          prompt,
          socket.assigns.selected_tag_ids,
          socket.assigns.current_user
        )

        if socket.assigns.create_mode? do
          if socket.assigns.tab_id do
            Phoenix.PubSub.broadcast(
              Magus.PubSub,
              "workbench-tabs:#{socket.assigns.current_user.id}",
              {:replace_new_tab_with_prompt, socket.assigns.tab_id, prompt.id}
            )
          end

          {:noreply,
           socket
           |> put_flash(:info, gettext("Prompt created successfully"))
           |> push_navigate(to: ~p"/prompts_library/#{prompt.id}")}
        else
          {:ok, refreshed} =
            Library.get_prompt(prompt.id,
              actor: socket.assigns.current_user,
              load: [:tags, :model]
            )

          {:noreply,
           socket
           |> assign(:prompt, refreshed)
           |> assign(:edit?, false)
           |> put_flash(:info, gettext("Prompt updated successfully"))}
        end

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/prompts_library")}
  end

  def handle_event("toggle_publish", _params, socket) do
    prompt = socket.assigns.prompt
    user = socket.assigns.current_user

    result =
      if prompt.is_public do
        Library.unpublish_prompt(prompt, actor: user)
      else
        Library.publish_prompt(prompt, %{is_public: true}, actor: user)
      end

    case result do
      {:ok, _} ->
        {:ok, refreshed} = Library.get_prompt(prompt.id, actor: user, load: [:tags, :model])

        flash =
          if refreshed.is_public,
            do: gettext("Prompt published to public library"),
            else: gettext("Prompt unpublished")

        {:noreply,
         socket
         |> assign(:prompt, refreshed)
         |> put_flash(:info, flash)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update prompt visibility"))}
    end
  end

  def handle_event("share_to_workspace", _params, socket) do
    {:noreply, toggle_prompt_share(socket, :share)}
  end

  def handle_event("unshare_from_workspace", _params, socket) do
    {:noreply, toggle_prompt_share(socket, :unshare)}
  end

  def handle_event("delete", _params, socket) do
    prompt = socket.assigns.prompt
    user = socket.assigns.current_user

    case Library.destroy_prompt(prompt, actor: user) do
      :ok ->
        if socket.assigns.tab_id do
          Phoenix.PubSub.broadcast(
            Magus.PubSub,
            "workbench-tabs:#{user.id}",
            {:close_workbench_tab, socket.assigns.tab_id}
          )
        end

        {:noreply,
         socket
         |> put_flash(:info, gettext("Prompt deleted"))
         |> push_navigate(to: ~p"/prompts_library")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete prompt"))}
    end
  end

  @impl true
  def handle_info({:set_edit_state, edit?}, socket) do
    if socket.assigns.not_found do
      {:noreply, socket}
    else
      socket =
        if edit? and not socket.assigns.edit? do
          socket
          |> assign(:edit?, true)
          |> load_form_data()
          |> assign_form(socket.assigns.prompt)
        else
          assign(socket, :edit?, edit?)
        end

      {:noreply, socket}
    end
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  defp update_prompt_tags(prompt, tag_ids, actor) do
    prompt_with_tags = Library.get_prompt!(prompt.id, actor: actor, load: [:tags])
    current_tag_ids = Enum.map(prompt_with_tags.tags || [], & &1.id)

    tags_to_add = tag_ids -- current_tag_ids
    tags_to_remove = current_tag_ids -- tag_ids

    if tags_to_add != [], do: Library.add_prompt_tags!(prompt, tags_to_add, actor: actor)
    Enum.each(tags_to_remove, &Library.remove_prompt_tag!(prompt, &1, actor: actor))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div data-prompt-view class="h-full flex flex-col">
      <div :if={@not_found} class="flex-1 flex items-center justify-center text-wb-text-muted">
        <p>Prompt not found.</p>
      </div>

      <div :if={not @not_found} class="flex-1 flex flex-col min-h-0">
        <%= cond do %>
          <% @create_mode? -> %>
            {render_create_form(assigns)}
          <% @edit? -> %>
            {render_edit_form(assigns)}
          <% true -> %>
            {render_inspect(assigns)}
        <% end %>
      </div>
    </div>
    """
  end

  defp render_inspect(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto">
      <div class="p-6 max-w-3xl mx-auto w-full">
        <header class="flex items-start gap-4 mb-6">
          <div class="w-14 h-14 rounded-xl bg-base-200 border border-base-300 flex items-center justify-center shrink-0">
            <.icon name={prompt_icon(@prompt)} class="w-7 h-7 text-base-content/60" />
          </div>
          <div class="flex-1 min-w-0">
            <h1 class="text-xl font-semibold truncate">{@prompt.name}</h1>
            <p class="text-xs uppercase tracking-wide text-base-content/60 mt-1">
              {prompt_type_label(@prompt.type)}<span
                :if={@prompt.chat_mode}
                class="ml-2"
              >· {@prompt.chat_mode} mode</span>
            </p>
          </div>
          <div class="flex gap-2 shrink-0">
            <.workspace_share_button resource={@prompt} class="btn btn-sm btn-outline" />
            <.link navigate={~p"/chat?use_prompt=#{@prompt.id}"} class="btn btn-sm btn-outline">
              <.icon name="lucide-message-circle" class="w-4 h-4" /> {gettext("Use prompt")}
            </.link>
            <button type="button" phx-click="enter_edit" class="btn btn-sm btn-primary">
              <.icon name="lucide-pencil" class="w-4 h-4" /> {gettext("Edit")}
            </button>
            <button
              type="button"
              phx-click="toggle_publish"
              class={[
                "btn btn-sm",
                if(@prompt.is_public, do: "btn-outline", else: "btn-outline btn-success")
              ]}
            >
              <.icon
                name={if @prompt.is_public, do: "lucide-eye-off", else: "lucide-globe"}
                class="w-4 h-4"
              />
              {if @prompt.is_public, do: gettext("Unpublish"), else: gettext("Publish")}
            </button>
            <button
              type="button"
              phx-click="delete"
              data-confirm={gettext("Delete this prompt? This cannot be undone.")}
              class="btn btn-sm btn-outline btn-error"
            >
              <.icon name="lucide-trash-2" class="w-4 h-4" /> {gettext("Delete")}
            </button>
          </div>
        </header>

        <div class="space-y-6">
          <.content_card :if={@prompt.description} title="Description" icon="lucide-file-text">
            <p class="text-sm leading-relaxed">{@prompt.description}</p>
          </.content_card>

          <.content_card title="Content" icon="lucide-code">
            <pre class="text-xs bg-base-100 border border-base-300 rounded p-3 whitespace-pre-wrap overflow-x-auto">{@prompt.content}</pre>
          </.content_card>

          <.content_card
            :if={@prompt.additional_information}
            title="Additional information"
            icon="lucide-book-open"
          >
            <p class="text-sm leading-relaxed whitespace-pre-wrap">
              {@prompt.additional_information}
            </p>
          </.content_card>

          <.content_card :if={@prompt.tags && @prompt.tags != []} title="Tags" icon="lucide-tag">
            <div class="flex flex-wrap gap-2">
              <span :for={tag <- @prompt.tags} class="badge badge-sm">#{tag.name}</span>
            </div>
          </.content_card>

          <.content_card title="Details" icon="lucide-info">
            <dl class="grid grid-cols-2 gap-4 text-sm">
              <div>
                <dt class="text-xs uppercase tracking-wide text-base-content/50">Type</dt>
                <dd>{prompt_type_label(@prompt.type)}</dd>
              </div>
              <div :if={@prompt.language}>
                <dt class="text-xs uppercase tracking-wide text-base-content/50">Language</dt>
                <dd>{language_label(@prompt.language)}</dd>
              </div>
              <div :if={@prompt.model}>
                <dt class="text-xs uppercase tracking-wide text-base-content/50">Default model</dt>
                <dd class="truncate">{@prompt.model.name}</dd>
              </div>
              <div :if={@prompt.chat_mode}>
                <dt class="text-xs uppercase tracking-wide text-base-content/50">Default mode</dt>
                <dd>{@prompt.chat_mode}</dd>
              </div>
              <div>
                <dt class="text-xs uppercase tracking-wide text-base-content/50">Visibility</dt>
                <dd>{if @prompt.is_public, do: "Public", else: "Private"}</dd>
              </div>
              <div :if={(@prompt.copy_count || 0) > 0}>
                <dt class="text-xs uppercase tracking-wide text-base-content/50">
                  Copies in library
                </dt>
                <dd>{@prompt.copy_count}</dd>
              </div>
            </dl>
          </.content_card>
        </div>
      </div>
    </div>
    """
  end

  defp language_label(:en), do: "English"
  defp language_label(:de), do: "German"
  defp language_label(:es), do: "Spanish"
  defp language_label(:fr), do: "French"
  defp language_label(:zh), do: "Chinese"
  defp language_label(:ja), do: "Japanese"
  defp language_label(:ko), do: "Korean"
  defp language_label(:pt), do: "Portuguese"
  defp language_label(:ru), do: "Russian"
  defp language_label(:ar), do: "Arabic"
  defp language_label(other), do: to_string(other)

  defp render_edit_form(assigns) do
    ~H"""
    <div data-prompt-edit class="flex-1 overflow-y-auto p-6 max-w-3xl mx-auto w-full">
      <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-6">
        <%!-- Basic Info Card --%>
        <div class="bg-wb-surface border border-wb-border rounded-xl p-5">
          <h2 class="text-base font-semibold mb-4">{gettext("Basic Information")}</h2>

          <div class="space-y-4">
            <.input
              field={@form[:name]}
              type="text"
              label={gettext("Name")}
              placeholder={gettext("Prompt name")}
              required
            />

            <.input
              field={@form[:description]}
              type="textarea"
              label={gettext("Description")}
              placeholder={gettext("Describe what this prompt does and when to use it...")}
              class="textarea h-20"
            />

            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@form[:type]}
                type="select"
                label={gettext("Type")}
                options={Enum.map(@prompt_types, &{type_label(&1), &1})}
                required
              />

              <.input
                field={@form[:language]}
                type="select"
                label={gettext("Language")}
                options={@language_options}
              />
            </div>
          </div>
        </div>

        <%!-- Content Card --%>
        <div class="bg-wb-surface border border-wb-border rounded-xl p-5">
          <h2 class="text-base font-semibold mb-4">{gettext("Prompt Content")}</h2>

          <.input
            field={@form[:content]}
            type="textarea"
            label={
              if @current_type == :system,
                do: gettext("System Prompt"),
                else: gettext("Content")
            }
            placeholder={
              if @current_type == :system,
                do: gettext("Enter the system prompt for this AI personality..."),
                else: gettext("Enter the prompt content...")
            }
            class="textarea h-48 font-mono text-sm"
            required
          />
        </div>

        <%!-- Presets Card (System prompts only) --%>
        <div
          :if={@current_type == :system}
          class="bg-wb-surface border border-wb-border rounded-xl p-5"
        >
          <h2 class="text-base font-semibold mb-4">{gettext("Presets")}</h2>

          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:model_id]}
              type="select"
              label={gettext("Default Model")}
              options={@model_options}
            />

            <.input
              field={@form[:chat_mode]}
              type="select"
              label={gettext("Default Chat Mode")}
              options={@chat_mode_options}
            />
          </div>
        </div>

        <%!-- Tags Card --%>
        <div class="bg-wb-surface border border-wb-border rounded-xl p-5">
          <h2 class="text-base font-semibold mb-4">{gettext("Tags")}</h2>

          <div class="flex flex-wrap gap-2 p-3 bg-wb-surface-2 rounded-lg min-h-[60px]">
            <button
              :for={tag <- @available_tags}
              type="button"
              phx-click="toggle_tag"
              phx-value-tag-id={tag.id}
              class={"content-tag cursor-pointer #{if tag.id in @selected_tag_ids, do: "content-tag-selected"}"}
            >
              #{tag.name}
            </button>
            <span :if={@available_tags == []} class="text-sm text-wb-text-muted">
              {gettext("No tags available")}
            </span>
          </div>
        </div>

        <%!-- Additional Information Card --%>
        <div class="bg-wb-surface border border-wb-border rounded-xl p-5">
          <h2 class="text-base font-semibold mb-4">{gettext("Additional Information")}</h2>

          <.input
            field={@form[:additional_information]}
            type="textarea"
            label={gettext("Additional Details")}
            placeholder={
              gettext("Add any additional notes, usage tips, or examples (markdown supported)...")
            }
            class="textarea h-32"
          />
          <p class="text-xs text-wb-text-muted mt-2">
            {gettext(
              "Supports markdown formatting. This will be displayed on the prompt detail page."
            )}
          </p>
        </div>

        <%!-- Actions --%>
        <div class="flex items-center justify-between pt-2 pb-6">
          <button
            type="button"
            phx-click={if @create_mode?, do: "cancel_create", else: "exit_edit"}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Cancel")}
          </button>
          <button type="submit" class="btn btn-primary btn-sm">
            {if @create_mode?, do: gettext("Create Prompt"), else: gettext("Save Changes")}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp render_create_form(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto">
      <div class="p-6 max-w-3xl mx-auto w-full">
        <header class="mb-6">
          <h1 class="text-xl font-semibold">{gettext("New Prompt")}</h1>
          <p class="text-sm text-wb-text-muted mt-1">
            {gettext("Create a reusable prompt to use across conversations.")}
          </p>
        </header>
        {render_edit_form(assigns)}
      </div>
    </div>
    """
  end

  defp prompt_icon(%{type: :system}), do: "lucide-sparkles"
  defp prompt_icon(_), do: "lucide-scroll-text"

  defp prompt_type_label(:system), do: "Persona"
  defp prompt_type_label(:user), do: "Prompt"
  defp prompt_type_label(_), do: "Prompt"

  defp type_label(:system), do: gettext("System")
  defp type_label(:user), do: gettext("User")

  defp toggle_prompt_share(socket, action) do
    user = socket.assigns.current_user
    prompt = socket.assigns.prompt

    result =
      case action do
        :share -> WorkspaceShare.share(:prompt, prompt, user)
        :unshare -> WorkspaceShare.unshare(:prompt, prompt, user)
      end

    case result do
      {:ok, _} ->
        case Library.get_prompt(prompt.id,
               actor: user,
               load: [:tags, :model, :is_shared_to_workspace]
             ) do
          {:ok, refreshed} -> assign(socket, :prompt, refreshed)
          _ -> socket
        end

      :no_workspace ->
        socket

      {:error, _} ->
        put_flash(socket, :error, prompt_share_error(action))
    end
  end

  defp prompt_share_error(:share), do: gettext("Couldn't share this prompt.")
  defp prompt_share_error(:unshare), do: gettext("Couldn't unshare this prompt.")
end
