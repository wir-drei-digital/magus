defmodule MagusWeb.AgentsLive.Components.FilePickerModalComponent do
  @moduledoc """
  LiveComponent that lets the user pick existing files to attach to a custom
  agent. Lists the user's library files and creates `CustomAgentAttachment`
  records on submit.
  """

  use MagusWeb, :live_component

  require Ash.Query

  @impl true
  def update(assigns, socket) do
    user = assigns.current_user

    files =
      Magus.Files.File
      |> Ash.Query.filter(type in [:document, :text])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(200)
      |> Ash.read!(actor: user)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:files, files)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="text-lg font-bold">{gettext("Pick files to attach")}</h3>
        <form phx-submit="confirm" phx-target={@myself} class="space-y-2">
          <ul class="max-h-96 overflow-y-auto">
            <li :for={f <- @files} class="flex items-center gap-2 py-1">
              <input type="checkbox" name="file_ids[]" value={f.id} />
              <span>{f.name}</span>
            </li>
          </ul>
          <div class="modal-action">
            <button type="button" class="btn" phx-click="close" phx-target={@myself}>
              {gettext("Cancel")}
            </button>
            <button type="submit" class="btn btn-primary">
              {gettext("Attach selected")}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("close", _, socket) do
    send(self(), {:close_picker, socket.assigns.id})
    {:noreply, socket}
  end

  def handle_event("confirm", params, socket) do
    user = socket.assigns.current_user
    file_ids = Map.get(params, "file_ids", [])

    Enum.each(file_ids, fn id ->
      Magus.Agents.create_attachment(
        %{custom_agent_id: socket.assigns.custom_agent_id, file_id: id, mode: :search},
        actor: user
      )
    end)

    send(self(), {:files_picked, socket.assigns.id})
    {:noreply, socket}
  end
end
