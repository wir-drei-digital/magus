defmodule MagusWeb.ChatLive.Components.Brain.BrainFilePickerModalComponent do
  @moduledoc """
  Modal for picking files to insert as `:file` blocks into a brain page.

  Browse tab lists files in the same workspace as the brain (or personal
  files for a personal brain). On confirm, sends `{:brain_files_picked,
  %{...}}` to the parent LiveView with the selected file ids; the parent
  delegates to `Magus.Brain.BodyAppender.append_file_by_id/4` per pick,
  which appends a `magus://file/<id>` markdown link to `page.body`.
  Cross-workspace selections are blocked server-side by the
  `Magus.Brain.Page.Validations.FileReferencesInWorkspace` validation
  inside `update_page_body`.

  Upload tab uploads new files via `Magus.Files.Upload.create_file_from_upload/5`
  scoped to the brain's workspace and routes the resulting file ids
  through the same `BodyAppender` funnel.
  """
  use MagusWeb, :live_component

  require Logger

  @pickable_types [:document, :text, :image, :video, :email]
  @max_upload_entries 5
  @max_file_size 50_000_000
  @max_picker_results 200

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:active_tab, :browse)
     |> allow_upload(:brain_file,
       accept: :any,
       max_entries: @max_upload_entries,
       max_file_size: @max_file_size
     )}
  end

  @impl true
  def update(assigns, socket) do
    user = assigns.current_user
    brain = assigns.brain

    files = list_scope_files(user, brain.workspace_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:files, files)
     |> assign(:filter, "")
     |> assign(:max_picker_results, @max_picker_results)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="text-lg font-bold">{gettext("Insert file")}</h3>

        <div role="tablist" class="tabs tabs-bordered mt-2">
          <button
            type="button"
            role="tab"
            phx-click="set_tab"
            phx-value-tab="browse"
            phx-target={@myself}
            class={["tab", @active_tab == :browse && "tab-active"]}
          >
            {gettext("Browse")}
          </button>
          <button
            type="button"
            role="tab"
            phx-click="set_tab"
            phx-value-tab="upload"
            phx-target={@myself}
            class={["tab", @active_tab == :upload && "tab-active"]}
          >
            {gettext("Upload")}
          </button>
        </div>

        <div :if={@active_tab == :browse}>
          <input
            type="text"
            phx-keyup="filter"
            phx-target={@myself}
            name="filter"
            placeholder={gettext("Filter by name…")}
            class="input input-bordered input-sm w-full mt-3"
            value={@filter}
          />

          <form phx-submit="confirm" phx-target={@myself} class="space-y-2 mt-3">
            <ul class="max-h-96 overflow-y-auto divide-y divide-base-300/50">
              <li
                :for={f <- visible_files(@files, @filter)}
                class="flex items-center gap-2 py-2"
              >
                <input
                  type="checkbox"
                  name="file_ids[]"
                  value={f.id}
                  class="checkbox checkbox-sm"
                />
                <span class="text-sm">{f.name}</span>
                <span class="text-xs text-base-content/40 ml-auto">{f.mime_type}</span>
              </li>
            </ul>
            <p
              :if={visible_files(@files, @filter) == []}
              class="text-sm text-base-content/50 text-center py-4"
            >
              {gettext("No files in this scope.")}
            </p>
            <p
              :if={length(@files) >= @max_picker_results}
              class="text-xs text-base-content/50 text-center pt-1"
            >
              {gettext("Showing first %{n} results — use the filter to narrow.",
                n: @max_picker_results
              )}
            </p>
            <div class="modal-action">
              <button type="button" class="btn" phx-click="close" phx-target={@myself}>
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary">
                {gettext("Insert")}
              </button>
            </div>
          </form>
        </div>

        <div :if={@active_tab == :upload} class="mt-3">
          <form
            id="brain-file-upload-form"
            phx-submit="upload"
            phx-change="validate_upload"
            phx-target={@myself}
            phx-drop-target={@uploads.brain_file.ref}
          >
            <label
              class="flex flex-col items-center justify-center gap-2 border-2 border-dashed border-base-300 rounded-lg p-6 cursor-pointer hover:border-primary/40 transition-colors"
              for={@uploads.brain_file.ref}
            >
              <.icon name="lucide-upload" class="w-6 h-6 text-base-content/50" />
              <span class="text-sm text-base-content/60">
                {gettext("Drop files here or click to choose")}
              </span>
              <.live_file_input upload={@uploads.brain_file} class="hidden" />
            </label>

            <ul class="text-xs text-base-content/70 mt-3 space-y-1">
              <li :for={entry <- @uploads.brain_file.entries} class="flex items-center gap-2">
                <span class="truncate flex-1">
                  {entry.client_name}
                  <span class="text-base-content/40 ml-1">{format_size(entry.client_size)}</span>
                </span>
                <progress
                  :if={entry.progress > 0 and entry.progress < 100}
                  max="100"
                  value={entry.progress}
                  class="progress progress-primary w-24"
                />
                <button
                  type="button"
                  phx-click="cancel_upload_entry"
                  phx-value-ref={entry.ref}
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs"
                  aria-label={gettext("Cancel")}
                >
                  ×
                </button>
              </li>
              <li
                :for={err <- upload_errors(@uploads.brain_file)}
                class="text-error"
              >
                {error_to_string(err)}
              </li>
              <li
                :for={{entry, errs} <- entry_errors(@uploads.brain_file)}
                class="text-error"
              >
                {entry.client_name}: {Enum.map_join(errs, ", ", &error_to_string/1)}
              </li>
            </ul>

            <div class="modal-action">
              <button type="button" class="btn" phx-click="close" phx-target={@myself}>
                {gettext("Cancel")}
              </button>
              <button
                type="submit"
                class="btn btn-primary"
                disabled={@uploads.brain_file.entries == []}
              >
                {gettext("Upload and insert")}
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("filter", %{"value" => value}, socket) do
    {:noreply, assign(socket, :filter, value || "")}
  end

  def handle_event("filter", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("set_tab", %{"tab" => tab}, socket) do
    case tab do
      "browse" -> {:noreply, assign(socket, :active_tab, :browse)}
      "upload" -> {:noreply, assign(socket, :active_tab, :upload)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close", _params, socket) do
    send(self(), {:close_brain_file_picker, socket.assigns.id})
    {:noreply, socket}
  end

  def handle_event("confirm", params, socket) do
    file_ids = Map.get(params, "file_ids", []) |> List.wrap()

    send(
      self(),
      {:brain_files_picked,
       %{
         id: socket.assigns.id,
         file_ids: file_ids,
         page_id: socket.assigns.page.id
       }}
    )

    {:noreply, socket}
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_upload_entry", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :brain_file, ref)}
  end

  def handle_event("upload", _params, socket) do
    user = socket.assigns.current_user
    brain = socket.assigns.brain
    page = socket.assigns.page

    upload_opts =
      [actor: user]
      |> maybe_put(:workspace_id, brain.workspace_id)

    results =
      consume_uploaded_entries(socket, :brain_file, fn %{path: path}, entry ->
        case File.read(path) do
          {:ok, content} ->
            case Magus.Files.Upload.create_file_from_upload(
                   content,
                   entry.client_name,
                   entry.client_type,
                   byte_size(content),
                   upload_opts
                 ) do
              {:ok, file} ->
                {:ok, {:ok, file.id}}

              {:error, reason} ->
                {:ok, {:error, entry.client_name, reason, entry}}
            end

          {:error, reason} ->
            {:ok, {:error, entry.client_name, {:read_error, reason}, entry}}
        end
      end)

    {file_ids, failures} =
      Enum.reduce(results, {[], []}, fn
        {:ok, id}, {ids, fails} ->
          {[id | ids], fails}

        {:error, name, reason, entry}, {ids, fails} ->
          {ids, [{name, reason, entry} | fails]}
      end)

    file_ids = Enum.reverse(file_ids)
    failures = Enum.reverse(failures)

    if failures != [] do
      Enum.each(failures, fn {name, reason, entry} ->
        Logger.warning("brain picker upload failed",
          reason: inspect(reason),
          filename: name,
          size: entry && entry.client_size,
          user_id: user && user.id,
          page_id: page && page.id,
          workspace_id: brain && brain.workspace_id
        )
      end)

      simplified_failures = Enum.map(failures, fn {name, reason, _entry} -> {name, reason} end)
      send(self(), {:brain_file_upload_failed, simplified_failures})
    end

    if file_ids != [] do
      send(
        self(),
        {:brain_files_picked,
         %{
           id: socket.assigns.id,
           file_ids: file_ids,
           page_id: socket.assigns.page.id
         }}
      )
    end

    {:noreply, socket}
  end

  # Use the Magus.Files domain code interfaces. They already filter by
  # `is_nil(deleted_at)` (Magus.Files.File has `base_filter` set), apply
  # workspace/personal scoping via Ash policies + action filters, and
  # sort by `updated_at: :desc`. We add a `:type` filter post-fetch for
  # the picker (only file types that make sense to embed in a brain page).
  # Switched to non-bang variants so a transient read failure does not
  # crash the picker render.
  defp list_scope_files(user, nil) do
    case Magus.Files.list_personal_library_files(actor: user) do
      {:ok, files} -> files |> filter_pickable() |> Enum.take(@max_picker_results)
      _ -> []
    end
  end

  defp list_scope_files(user, workspace_id) do
    case Magus.Files.list_workspace_library_files(workspace_id, actor: user) do
      {:ok, files} -> files |> filter_pickable() |> Enum.take(@max_picker_results)
      _ -> []
    end
  end

  defp filter_pickable(files) do
    Enum.filter(files, fn f -> f.type in @pickable_types end)
  end

  defp visible_files(files, ""), do: files

  defp visible_files(files, filter) do
    f = String.downcase(filter)
    Enum.filter(files, &String.contains?(String.downcase(&1.name || ""), f))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp entry_errors(upload) do
    upload.entries
    |> Enum.map(fn entry -> {entry, upload_errors(upload, entry)} end)
    |> Enum.reject(fn {_entry, errs} -> errs == [] end)
  end

  defp error_to_string(:too_large), do: gettext("File too large (max 50MB)")
  defp error_to_string(:not_accepted), do: gettext("File type not accepted")
  defp error_to_string(:too_many_files), do: gettext("Too many files (max 5)")
  defp error_to_string(err), do: to_string(err)

  defp format_size(nil), do: ""
  defp format_size(b) when b < 1024, do: "#{b} B"
  defp format_size(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_size(b), do: "#{Float.round(b / 1024 / 1024, 1)} MB"
end
