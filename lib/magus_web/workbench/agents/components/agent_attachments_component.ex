defmodule MagusWeb.AgentsLive.Components.AgentAttachmentsComponent do
  @moduledoc """
  LiveComponent for managing files attached directly to a custom agent.

  Renders the list of attachments, mode toggle (always vs. search), upload
  control, file picker entry, drag-to-reorder, and a token-usage indicator
  for always-include attachments.
  """

  use MagusWeb, :live_component

  alias Magus.Agents
  alias Magus.Agents.AttachmentLimits

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:always_tokens, 0)
     |> assign(:total_size, 0)
     |> assign(:show_picker, false)
     |> allow_upload(:files,
       accept: ~w(.pdf .txt .md .docx),
       max_entries: 5,
       max_file_size: 25 * 1024 * 1024
     )}
  end

  @impl true
  def update(%{custom_agent_id: agent_id, current_user: user} = assigns, socket) do
    attachments =
      Agents.list_agent_attachments!(agent_id,
        actor: user,
        load: [file: [:chunks]]
      )

    always_tokens = sum_always_tokens(attachments)
    total_size = Enum.reduce(attachments, 0, fn a, acc -> acc + (a.file.file_size || 0) end)

    {:ok,
     socket
     |> assign(assigns)
     |> stream(:attachments, attachments, reset: true)
     |> assign(:always_tokens, always_tokens)
     |> assign(:total_size, total_size)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4" id={@id}>
      <header class="flex items-center justify-between">
        <h3 class="text-lg font-semibold">{gettext("Attached documents")}</h3>
        <div class="flex items-center gap-2">
          <form phx-submit="upload" phx-change="validate_upload" phx-target={@myself}>
            <label class="btn btn-sm btn-primary cursor-pointer" data-role="upload-trigger">
              {gettext("Upload file")}
              <.live_file_input upload={@uploads.files} class="hidden" />
            </label>
            <div :if={Enum.any?(@uploads.files.entries)} class="flex items-center gap-2 mt-1">
              <ul class="text-xs text-base-content/70" data-role="upload-entries">
                <li :for={entry <- @uploads.files.entries}>{entry.client_name}</li>
              </ul>
              <button class="btn btn-sm" type="submit" data-role="confirm-upload">
                {gettext("Confirm upload")}
              </button>
            </div>
          </form>
          <button
            type="button"
            class="btn btn-sm"
            phx-click="open_picker"
            phx-target={@myself}
            data-role="open-picker"
          >
            {gettext("Pick from files")}
          </button>
        </div>
      </header>

      <div
        id="attachments-list"
        phx-update="stream"
        phx-hook=".SortableAttachments"
        phx-target={@myself}
        class="space-y-2"
      >
        <div
          :for={{dom_id, att} <- @streams.attachments}
          id={dom_id}
          class="flex items-center justify-between gap-4 rounded border p-3"
          data-position={att.position}
        >
          <div class="flex flex-1 items-center gap-3 min-w-0">
            <span class="cursor-grab" title="Reorder">≡</span>
            <span class="truncate">{att.file.name}</span>
            <span class="text-xs text-base-content/60">{format_size(att.file.file_size)}</span>
            <span class={status_class(att.file.status)}>{att.file.status}</span>
          </div>
          <div class="flex items-center gap-2">
            <select
              phx-change="update_mode"
              phx-target={@myself}
              phx-value-id={att.id}
              name="mode"
              disabled={att.file.status != :ready}
            >
              <option value="always" selected={att.mode == :always}>{gettext("Always")}</option>
              <option value="search" selected={att.mode == :search}>{gettext("Search")}</option>
            </select>
            <button
              type="button"
              phx-click="remove_attachment"
              phx-target={@myself}
              phx-value-id={att.id}
              class="btn btn-sm btn-ghost"
              aria-label={gettext("Remove")}
            >
              ×
            </button>
          </div>
        </div>
      </div>

      <div class="text-sm">
        {gettext("Always-include token usage:")}
        <span class={token_class(@always_tokens)}>
          {format_int(@always_tokens)} / {format_int(AttachmentLimits.max_always_include_tokens())}
        </span>
      </div>

      <.live_component
        :if={@show_picker}
        module={MagusWeb.AgentsLive.Components.FilePickerModalComponent}
        id="file-picker-modal"
        custom_agent_id={@custom_agent_id}
        current_user={@current_user}
      />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SortableAttachments">
        export default {
          mounted() {
            const list = this.el;
            let dragged = null;

            const refresh = () => {
              list.querySelectorAll('[data-position]').forEach(row => {
                if (row.dataset.dragBound === '1') return;
                row.dataset.dragBound = '1';
                row.draggable = true;
                row.addEventListener('dragstart', () => { dragged = row; });
                row.addEventListener('dragover', e => e.preventDefault());
                row.addEventListener('drop', e => {
                  e.preventDefault();
                  if (dragged && dragged !== row) {
                    list.insertBefore(dragged, row);
                    const ids = [...list.querySelectorAll('[data-position]')]
                      .map(el => el.id.replace(/^attachments-/, ''));
                    this.pushEventTo(this.el, 'reorder', { ordered_ids: ids });
                  }
                  dragged = null;
                });
              });
            };

            refresh();
            this.handleEvent('phx:update', refresh);
          },
          updated() {
            this.mounted();
          }
        }
      </script>
    </section>
    """
  end

  @impl true
  def handle_event("update_mode", %{"id" => id, "mode" => mode}, socket) do
    user = socket.assigns.current_user
    {:ok, attachment} = Ash.get(Magus.Agents.CustomAgentAttachment, id, actor: user)

    case Agents.update_attachment(attachment, %{mode: String.to_existing_atom(mode)}, actor: user) do
      {:ok, _} ->
        send_update(__MODULE__,
          id: socket.assigns.id,
          custom_agent_id: socket.assigns.custom_agent_id,
          current_user: user
        )

        {:noreply, socket}

      {:error, %Ash.Error.Invalid{} = err} ->
        {:noreply, put_flash(socket, :error, Exception.message(err))}
    end
  end

  def handle_event("remove_attachment", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    {:ok, attachment} = Ash.get(Magus.Agents.CustomAgentAttachment, id, actor: user)
    :ok = Agents.destroy_attachment(attachment, actor: user)

    send_update(__MODULE__,
      id: socket.assigns.id,
      custom_agent_id: socket.assigns.custom_agent_id,
      current_user: user
    )

    {:noreply, socket}
  end

  def handle_event("open_picker", _, socket), do: {:noreply, assign(socket, :show_picker, true)}

  def handle_event("reorder", %{"ordered_ids" => ids}, socket) do
    user = socket.assigns.current_user

    ids
    |> Enum.with_index()
    |> Enum.each(fn {id, idx} ->
      {:ok, att} = Ash.get(Magus.Agents.CustomAgentAttachment, id, actor: user)
      Agents.update_attachment(att, %{position: idx}, actor: user)
    end)

    send_update(__MODULE__,
      id: socket.assigns.id,
      custom_agent_id: socket.assigns.custom_agent_id,
      current_user: user
    )

    {:noreply, socket}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("upload", _params, socket) do
    user = socket.assigns.current_user
    agent_id = socket.assigns.custom_agent_id
    agent = Agents.get_custom_agent!(agent_id, actor: user)

    results =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        content = File.read!(path)

        upload_result =
          Magus.Files.Upload.create_file_from_upload(
            content,
            entry.client_name,
            entry.client_type,
            byte_size(content),
            actor: user,
            workspace_id: agent.workspace_id,
            extra_attrs: %{uploaded_via_agent_id: agent.id}
          )

        case upload_result do
          {:ok, file} ->
            attachment_result =
              Agents.create_attachment(
                %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
                actor: user
              )

            {:ok, attachment_result}

          {:error, reason} ->
            {:postpone, {:error, entry.client_name, reason}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _, _}, &1))

    socket =
      if errors == [] do
        socket
      else
        put_flash(socket, :error, gettext("Some uploads failed."))
      end

    send_update(__MODULE__,
      id: socket.assigns.id,
      custom_agent_id: socket.assigns.custom_agent_id,
      current_user: user
    )

    {:noreply, socket}
  end

  defp sum_always_tokens(attachments) do
    attachments
    |> Enum.filter(&(&1.mode == :always))
    |> Enum.flat_map(fn a ->
      case a.file && a.file.chunks do
        chunks when is_list(chunks) -> chunks
        _ -> []
      end
    end)
    |> Enum.reduce(0, fn c, acc -> acc + (c.token_count || 0) end)
  end

  defp format_size(nil), do: "-"
  defp format_size(b) when b < 1024, do: "#{b} B"
  defp format_size(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_size(b), do: "#{Float.round(b / 1024 / 1024, 1)} MB"

  defp format_int(n) do
    n
    |> Integer.to_string()
    |> String.replace(~r/(\d)(?=(\d{3})+$)/, "\\1,")
  end

  defp token_class(n) do
    cond do
      n > AttachmentLimits.max_always_include_tokens() -> "text-error font-semibold"
      n > AttachmentLimits.always_include_warning_threshold() -> "text-warning font-semibold"
      true -> "text-base-content/70"
    end
  end

  defp status_class(:ready), do: "text-success"
  defp status_class(:processing), do: "text-warning"
  defp status_class(_), do: "text-base-content/60"
end
