defmodule MagusWeb.ChatLive.Components.PromptFormModalComponent do
  @moduledoc """
  Reusable LiveComponent for creating and editing prompts.

  Can be used from:
  - LibrarySidebarComponent (in chat)
  - PromptsLive (prompts library)

  ## Usage

      <.live_component
        module={MagusWeb.ChatLive.Components.PromptFormModalComponent}
        id="prompt-form-modal"
        show={@show_prompt_form}
        prompt={@editing_prompt}
        current_user={@current_user}
      />

  ## Events sent to parent

  - `{PromptFormModalComponent, {:prompt_saved, prompt}}` - When a prompt is created/updated
  - `{PromptFormModalComponent, :modal_closed}` - When the modal is closed/cancelled
  """
  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  alias AshPhoenix.Form

  @prompt_types [:user, :system]

  def render(assigns) do
    ~H"""
    <div>
      <.modal id="prompt-form-modal" show={@show} on_close="cancel" target={@myself}>
        <:title>{if @prompt, do: gettext("Edit Prompt"), else: gettext("New Prompt")}</:title>

        <.form for={@form} phx-submit="save" phx-change="validate" phx-target={@myself}>
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            placeholder={gettext("Prompt name")}
            required
          />
          <.input
            field={@form[:type]}
            type="select"
            label={gettext("Type")}
            options={Enum.map(@prompt_types, &{type_label(&1), &1})}
            required
          />
          <.input
            field={@form[:content]}
            type="textarea"
            label={
              if @current_type == :system, do: gettext("System Prompt"), else: gettext("Content")
            }
            placeholder={
              if @current_type == :system,
                do: gettext("Enter the system prompt for this AI personality..."),
                else: gettext("Enter the prompt content...")
            }
            class="textarea h-32"
            phx-hook=".PreserveResize"
            required
          />
          <script :type={Phoenix.LiveView.ColocatedHook} name=".PreserveResize">
            export default {
              mounted() {
                this._height = null;
              },
              beforeUpdate() {
                this._height = this.el.style.height || this.el.offsetHeight + "px";
              },
              updated() {
                if (this._height) {
                  this.el.style.height = this._height;
                }
              }
            }
          </script>

          <%!-- System prompt presets --%>
          <div :if={@current_type == :system} class="divider text-xs text-base-content/50">
            {gettext("Presets (optional)")}
          </div>

          <.input
            :if={@current_type == :system}
            field={@form[:model_id]}
            type="select"
            label={gettext("Default Model")}
            options={@model_options}
          />

          <.input
            :if={@current_type == :system}
            field={@form[:chat_mode]}
            type="select"
            label={gettext("Default Chat Mode")}
            options={@chat_mode_options}
          />

          <div class="fieldset mb-2">
            <label>
              <span class="label mb-1">{gettext("Tags")}</span>
            </label>
            <div class="flex flex-wrap gap-2 p-3 bg-base-200 rounded-lg min-h-[60px]">
              <button
                :for={tag <- @available_tags}
                type="button"
                phx-click="toggle_tag"
                phx-value-tag-id={tag.id}
                phx-target={@myself}
                class={"content-tag cursor-pointer #{if tag.id in @selected_tag_ids, do: "content-tag-selected"}"}
              >
                #{tag.name}
              </button>
              <span :if={@available_tags == []} class="text-xs text-base-content/50">
                {gettext("No tags available")}
              </span>
            </div>
          </div>
          <div class="modal-action">
            <button type="button" class="btn" phx-click="cancel" phx-target={@myself}>
              {gettext("Cancel")}
            </button>
            <button type="submit" class="btn btn-primary">
              {if @prompt, do: gettext("Update"), else: gettext("Create")}
            </button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     |> assign(:show, false)
     |> assign(:prompt, nil)
     |> assign(:prompt_types, @prompt_types)
     |> assign(:available_tags, [])
     |> assign(:selected_tag_ids, [])
     |> assign(:models, [])
     |> assign(:current_type, :user)
     |> assign(:model_options, [])
     |> assign(:chat_mode_options, [])
     |> assign_form(nil)}
  end

  def update(%{show: true} = assigns, socket) do
    prompt = assigns[:prompt]

    # Load available tags and models
    available_tags = Magus.Library.list_tags!()
    models = Magus.Chat.list_active_models!()

    # Get selected tag IDs if editing
    selected_tag_ids =
      if prompt do
        prompt = Ash.load!(prompt, [:tags], actor: assigns.current_user)
        Enum.map(prompt.tags || [], & &1.id)
      else
        []
      end

    model_options =
      [{"None (use conversation default)", nil}] ++
        Enum.map(models, &{&1.name, &1.id})

    chat_mode_options = [
      {"Chat", :chat},
      {"Search", :search},
      {"Reasoning", :reasoning},
      {"Image Generation", :image_generation},
      {"Video Generation", :video_generation}
    ]

    current_type =
      if prompt, do: prompt.type || :user, else: :user

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:available_tags, available_tags)
     |> assign(:selected_tag_ids, selected_tag_ids)
     |> assign(:models, models)
     |> assign(:model_options, model_options)
     |> assign(:chat_mode_options, chat_mode_options)
     |> assign(:current_type, current_type)
     |> assign_form(prompt)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    form = Form.validate(socket.assigns.form.source, params)

    # Update current_type based on form value
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
    case Form.submit(socket.assigns.form.source, params: params) do
      {:ok, prompt} ->
        update_prompt_tags(
          prompt,
          socket.assigns.selected_tag_ids,
          socket.assigns.current_user
        )

        # Reload prompt with associations
        prompt =
          Magus.Library.get_prompt!(prompt.id,
            actor: socket.assigns.current_user,
            load: [:tags, :model, :user]
          )

        notify_parent({:prompt_saved, prompt})

        {:noreply,
         socket
         |> assign(:show, false)
         |> assign(:prompt, nil)
         |> assign(:selected_tag_ids, [])}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  def handle_event("cancel", _, socket) do
    notify_parent(:modal_closed)

    {:noreply,
     socket
     |> assign(:show, false)
     |> assign(:prompt, nil)
     |> assign(:selected_tag_ids, [])}
  end

  defp assign_form(socket, prompt) do
    form =
      if prompt do
        Form.for_update(prompt, :update, actor: socket.assigns[:current_user])
      else
        Form.for_create(Magus.Library.Prompt, :create, actor: socket.assigns[:current_user])
      end

    assign(socket, :form, to_form(form))
  end

  defp update_prompt_tags(prompt, tag_ids, actor) do
    prompt_with_tags = Magus.Library.get_prompt!(prompt.id, actor: actor, load: [:tags])
    current_tag_ids = Enum.map(prompt_with_tags.tags || [], & &1.id)

    tags_to_add = tag_ids -- current_tag_ids
    tags_to_remove = current_tag_ids -- tag_ids

    if tags_to_add != [], do: Magus.Library.add_prompt_tags!(prompt, tags_to_add, actor: actor)
    Enum.each(tags_to_remove, &Magus.Library.remove_prompt_tag!(prompt, &1, actor: actor))
  end

  defp type_label(:system), do: gettext("System")
  defp type_label(:user), do: gettext("User")
end
