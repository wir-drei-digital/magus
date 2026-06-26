defmodule MagusWeb.ChatLive.Components.CreatePromptModalComponent do
  @moduledoc """
  LiveComponent for creating a prompt from a message or conversation.

  Handles:
  - Creating prompts from single messages (pre-filled content)
  - Creating prompts from conversations (AI-generated content)
  - User can override name, type, and content
  """
  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  @prompt_types [:user, :system]

  def render(assigns) do
    ~H"""
    <div>
      <.modal id="create-prompt-modal" show={@show} on_close="cancel" target={@myself}>
        <:title>{gettext("Create Prompt")}</:title>

        <%= if @loading do %>
          <div class="flex flex-col items-center justify-center py-8 gap-4">
            <span class="loading loading-spinner loading-lg text-primary"></span>
            <p class="text-sm text-base-content/60">{gettext("Analyzing conversation...")}</p>
          </div>
        <% else %>
          <.form
            for={@form}
            phx-submit="save_prompt"
            phx-change="validate_prompt"
            phx-target={@myself}
          >
            <.input
              field={@form[:name]}
              type="text"
              label={gettext("Name")}
              placeholder={gettext("Leave empty to auto-generate")}
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
              label={gettext("Content")}
              placeholder={gettext("Enter the prompt content...")}
              class="textarea h-32"
              required
            />
            <div class="modal-action">
              <button type="button" class="btn" phx-click="cancel" phx-target={@myself}>
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary">
                {gettext("Create")}
              </button>
            </div>
          </.form>
        <% end %>
      </.modal>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     |> assign(:show, false)
     |> assign(:loading, false)
     |> assign(:prompt_types, @prompt_types)
     |> assign(:source_message, nil)
     |> assign(:source_conversation_id, nil)
     |> assign_form(%{})}
  end

  def update(%{show: true, message: message} = assigns, socket) when not is_nil(message) do
    # Creating from a single message - content is the message text
    socket =
      socket
      |> assign(assigns)
      |> assign(:source_message, message)
      |> assign(:source_conversation_id, nil)
      |> assign(:loading, false)
      |> assign_form(%{
        "content" => message.text,
        "type" => "user",
        "name" => ""
      })

    {:ok, socket}
  end

  def update(
        %{show: true, conversation_id: conversation_id, generated: generated} = assigns,
        socket
      )
      when is_map(generated) do
    # AI has already generated the prompt content
    socket =
      socket
      |> assign(assigns)
      |> assign(:source_message, nil)
      |> assign(:source_conversation_id, conversation_id)
      |> assign(:loading, false)
      |> assign_form(%{
        "content" => generated.content,
        "type" => to_string(generated.suggested_type),
        "name" => generated.suggested_name
      })

    {:ok, socket}
  end

  def update(%{show: true, conversation_id: conversation_id} = assigns, socket)
      when not is_nil(conversation_id) do
    # Creating from conversation - need to generate content
    socket =
      socket
      |> assign(assigns)
      |> assign(:source_message, nil)
      |> assign(:source_conversation_id, conversation_id)
      |> assign(:loading, true)
      |> assign_form(%{})

    # Notify parent to start generation
    send(self(), {__MODULE__, {:start_generation, conversation_id}})

    {:ok, socket}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def handle_event("validate_prompt", %{"create_prompt" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("save_prompt", %{"create_prompt" => params}, socket) do
    # Treat empty name as nil to trigger auto-generation
    name =
      case String.trim(params["name"] || "") do
        "" -> nil
        n -> n
      end

    result =
      if socket.assigns.source_message do
        # Create from message
        Magus.Library.create_prompt_from_message(
          socket.assigns.source_message.id,
          %{
            name: name,
            type: String.to_existing_atom(params["type"]),
            content: params["content"]
          },
          actor: socket.assigns.current_user
        )
      else
        # Create directly (content already generated)
        Magus.Library.create_prompt(
          %{
            name: name || "New Prompt",
            type: String.to_existing_atom(params["type"]),
            content: params["content"]
          },
          actor: socket.assigns.current_user
        )
      end

    case result do
      {:ok, _prompt} ->
        notify_parent(:prompt_created)
        {:noreply, assign(socket, :show, false)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :create_prompt))}
    end
  end

  def handle_event("cancel", _, socket) do
    notify_parent(:modal_closed)
    {:noreply, assign(socket, :show, false)}
  end

  defp assign_form(socket, params) do
    form =
      %{
        "name" => params["name"] || "",
        "type" => params["type"] || "user",
        "content" => params["content"] || ""
      }
      |> to_form(as: :create_prompt)

    assign(socket, :form, form)
  end

  defp type_label(:system), do: gettext("System")
  defp type_label(:user), do: gettext("User")
end
