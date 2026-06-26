defmodule MagusWeb.Workbench.Resources.AgentView.Sections.Tools do
  @moduledoc """
  Model & Tools agent settings section, ported from AgentToolsLive.
  """
  use MagusWeb, :live_component

  use Gettext, backend: MagusWeb.Gettext

  alias AshPhoenix.Form

  @tool_categories [
    {:web, "Web (search, fetch)"},
    {:code, "Code (sandbox, exec)"},
    {:memory, "Memory"},
    {:files, "Files (RAG, drafts)"},
    {:skills, "Skills"},
    {:tasks, "Tasks"},
    {:integrations, "Integrations"}
  ]

  @category_string_to_atom Map.new(@tool_categories, fn {atom, _} ->
                             {Atom.to_string(atom), atom}
                           end)

  @impl true
  def update(%{agent: agent, current_user: current_user} = assigns, socket) do
    form =
      agent
      |> Form.for_update(:update, actor: current_user, forms: [auto?: true])
      |> to_form()

    all_models = Magus.Chat.list_active_models!()
    selected_mode = to_string(agent.chat_mode || "chat")

    auto_option = [{gettext("Auto (default)"), ""}]
    chat_models = auto_option ++ models_for_modality(all_models, "text")
    image_models = auto_option ++ models_for_modality(all_models, "image")
    video_models = auto_option ++ models_for_modality(all_models, "video")

    chat_models = ensure_current_model(chat_models, agent.model)
    image_models = ensure_current_model(image_models, agent.image_model)
    video_models = ensure_current_model(video_models, agent.video_model)

    chat_mode_options = [
      {gettext("Chat"), "chat"},
      {gettext("Image Generation"), "image_generation"},
      {gettext("Video Generation"), "video_generation"}
    ]

    available_skills = Magus.Agents.Skills.Registry.list_skills()

    disabled = agent.disabled_tool_categories || []
    selected_skills = agent.pre_loaded_skills || []

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, form)
     |> assign(:all_models, all_models)
     |> assign(:chat_model_options, chat_models)
     |> assign(:image_model_options, image_models)
     |> assign(:video_model_options, video_models)
     |> assign(:chat_mode_options, chat_mode_options)
     |> assign(:selected_mode, selected_mode)
     |> assign(:disabled_categories, disabled)
     |> assign(:selected_skills, selected_skills)
     |> assign(:available_skills, available_skills)
     |> assign(:tool_categories, @tool_categories)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div data-section="tools" class="p-4">
      <.form for={@form} phx-change="validate" phx-submit="save" phx-target={@myself}>
        <div class="space-y-6">
          <.content_card title={gettext("Mode & Model")} icon="lucide-cpu">
            <div class="space-y-4">
              <div class="grid grid-cols-2 gap-4">
                <.input
                  field={@form[:chat_mode]}
                  type="select"
                  label={gettext("Default Mode")}
                  options={@chat_mode_options}
                />
                <.input
                  field={@form[:max_iterations]}
                  type="number"
                  label={gettext("Max Iterations")}
                  min="1"
                  placeholder={gettext("Default")}
                />
              </div>

              <div :if={@selected_mode not in ["image_generation", "video_generation"]}>
                <.input
                  field={@form[:model_id]}
                  type="select"
                  label={gettext("Chat Model")}
                  options={@chat_model_options}
                />
              </div>
              <div :if={@selected_mode == "image_generation"}>
                <.input
                  field={@form[:image_model_id]}
                  type="select"
                  label={gettext("Image Model")}
                  options={@image_model_options}
                />
              </div>
              <div :if={@selected_mode == "video_generation"}>
                <.input
                  field={@form[:video_model_id]}
                  type="select"
                  label={gettext("Video Model")}
                  options={@video_model_options}
                />
              </div>
            </div>
          </.content_card>

          <.content_card
            title={gettext("Tools & Skills")}
            icon="lucide-wrench"
            subtitle={gettext("Control which tool categories this agent can use.")}
          >
            <div class="flex flex-wrap gap-2">
              <label
                :for={{cat, label} <- @tool_categories}
                class="flex items-center gap-2 px-3 py-1.5 bg-base-200 rounded-lg cursor-pointer hover:bg-base-300 transition-colors"
              >
                <input
                  type="checkbox"
                  class="checkbox checkbox-xs checkbox-primary"
                  checked={cat not in @disabled_categories}
                  phx-click="toggle_category"
                  phx-value-category={cat}
                  phx-target={@myself}
                />
                <span class="text-sm">{label}</span>
              </label>
            </div>

            <div :if={@available_skills != []} class="mt-6">
              <h3 class="text-sm font-medium text-base-content mb-2">
                {gettext("Pre-loaded Skills")}
              </h3>
              <p class="text-xs text-base-content/50 mb-3">
                {gettext(
                  "Skills that are always available to this agent without needing to load them."
                )}
              </p>
              <div class="flex flex-wrap gap-2">
                <button
                  :for={skill <- @available_skills}
                  type="button"
                  phx-click="toggle_skill"
                  phx-value-name={skill.name}
                  phx-target={@myself}
                  class={"content-tag cursor-pointer #{if skill.name in @selected_skills, do: "content-tag-selected"}"}
                >
                  {skill.name}
                </button>
              </div>
            </div>
          </.content_card>

          <div class="flex justify-end">
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              phx-disable-with={gettext("Saving...")}
            >
              {gettext("Save")}
            </button>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = Form.validate(socket.assigns.form.source, normalize_model_ids(params))

    {:noreply,
     socket
     |> assign(:form, to_form(form))
     |> assign(:selected_mode, params["chat_mode"] || "")}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save", %{"form" => params}, socket) when is_map(params) do
    params =
      params
      |> normalize_model_ids()
      |> Map.put("disabled_tool_categories", socket.assigns.disabled_categories)
      |> Map.put("pre_loaded_skills", socket.assigns.selected_skills)

    case Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, gettext("Model & Tools settings saved"))}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  def handle_event("save", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_category", %{"category" => category}, socket) do
    case Map.get(@category_string_to_atom, category) do
      nil ->
        {:noreply, socket}

      cat ->
        current = socket.assigns.disabled_categories

        new_disabled =
          if cat in current,
            do: List.delete(current, cat),
            else: [cat | current]

        {:noreply, assign(socket, :disabled_categories, new_disabled)}
    end
  end

  def handle_event("toggle_skill", %{"name" => name}, socket) do
    current = socket.assigns.selected_skills

    new_skills =
      if name in current,
        do: List.delete(current, name),
        else: [name | current]

    {:noreply, assign(socket, :selected_skills, new_skills)}
  end

  defp models_for_modality(models, modality) do
    models
    |> Enum.filter(fn model ->
      modality in (model.output_modalities || [])
    end)
    |> Enum.map(&{&1.name, &1.id})
  end

  @model_id_keys ~w(model_id image_model_id video_model_id)
  defp normalize_model_ids(params) do
    Enum.reduce(@model_id_keys, params, fn key, acc ->
      case Map.get(acc, key) do
        "" -> Map.put(acc, key, nil)
        _ -> acc
      end
    end)
  end

  defp ensure_current_model(options, nil), do: options
  defp ensure_current_model(options, %Ash.NotLoaded{}), do: options

  defp ensure_current_model(options, model) do
    if Enum.any?(options, fn {_name, id} -> id == model.id end) do
      options
    else
      options ++ [{model.name, model.id}]
    end
  end
end
