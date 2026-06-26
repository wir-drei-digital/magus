defmodule MagusWeb.Workbench.Resources.Companions.SpreadsheetCompanion do
  @moduledoc """
  LiveView companion for editing `.xlsx` files. Mounted via `live_render`
  from `TabContainer` (or directly from `FileView` when an `.xlsx` is the
  primary resource of a workbench tab).

  Receives in session:
    - `"file_id"` (required) UUID of the file
    - `"user_id"` (required) UUID of the current user
    - `"tab_id"` (required) workbench tab id (for broadcast_close_companion)

  Owns:
    - Loading the file's binary, base64-encoding it, and pushing it down
      to the colocated Univer hook on mount via `spreadsheet:load`.
    - Saving the binary on `spreadsheet:save` events from the hook by
      calling `Magus.Files.replace_file_content/4` with `source: :user`.
    - Subscribing to `"files:\#{file_id}"` so agent-side writes refresh
      the grid; ignores its own most recent save (matched by `request_id`)
      to avoid clobbering the user's pending edits with a redundant
      reload.
  """
  use MagusWeb, :live_view

  on_mount Magus.Presence

  import MagusWeb.Components.PresenceIndicator

  alias MagusWeb.Workbench.Signals
  alias Phoenix.PubSub

  @impl true
  def mount(_params, session, socket) do
    file_id = session["file_id"]
    user_id = session["user_id"]
    tab_id = session["tab_id"]

    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    case Magus.Files.get_file(file_id, actor: user) do
      {:ok, file} ->
        if connected?(socket) do
          PubSub.subscribe(Magus.PubSub, "files:#{file_id}")
        end

        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:file, file)
          |> assign(:tab_id, tab_id)
          |> assign(:save_state, :saved)
          |> assign(:last_request_id, nil)
          |> push_load_event(file, user)
          |> Magus.Presence.track(:spreadsheet, file.id)

        {:ok, socket}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:file, nil)
         |> assign(:tab_id, tab_id)
         |> assign(:save_state, :saved)
         |> assign(:last_request_id, nil)}
    end
  end

  @impl true
  def handle_event("spreadsheet:save", %{"binary" => b64}, socket) do
    request_id = Ecto.UUID.generate()

    with {:ok, binary} <- Base.decode64(b64),
         {:ok, updated} <-
           Magus.Files.replace_file_content(
             socket.assigns.file,
             binary,
             %{request_id: request_id, source: :user},
             actor: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> assign(:file, updated)
       |> assign(:save_state, :saved)
       |> assign(:last_request_id, request_id)
       |> push_event("spreadsheet:saved", %{at: DateTime.utc_now() |> DateTime.to_iso8601()})}
    else
      :error ->
        {:noreply, assign(socket, :save_state, :error)}

      {:error, _reason} ->
        {:noreply, assign(socket, :save_state, :error)}
    end
  end

  def handle_event("close_pane", _params, socket) do
    Signals.broadcast_close_companion(socket.assigns.tab_id)
    {:noreply, socket}
  end

  def handle_event(_unhandled, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:file_updated, _id, _source, request_id}, socket)
      when is_binary(request_id) and request_id == socket.assigns.last_request_id do
    # Echo of our own save: nothing new to load.
    {:noreply, socket}
  end

  def handle_info({:file_updated, _id, source, _request_id}, socket) do
    case Magus.Files.get_file(socket.assigns.file.id, actor: socket.assigns.current_user) do
      {:ok, file} ->
        socket =
          socket
          |> assign(:file, file)
          |> push_load_event(file, socket.assigns.current_user)

        socket =
          if source == :agent do
            push_event(socket, "spreadsheet:updated_by_agent", %{file_id: file.id})
          else
            socket
          end

        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:file_deleted, _id}, socket) do
    {:noreply, push_event(socket, "spreadsheet:deleted", %{})}
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section
      data-spreadsheet-companion
      data-file-id={if @file, do: @file.id, else: nil}
      class="h-full flex flex-col"
    >
      <header class="flex items-center justify-between border-b border-wb-border px-3 py-2 text-sm">
        <span class="truncate font-medium">
          {if @file, do: @file.name, else: gettext("Spreadsheet not available")}
        </span>
        <.save_indicator state={@save_state} />
      </header>

      <div :if={@file} class="flex items-center justify-end px-3 py-1 border-b border-base-200">
        <.presence_indicator
          viewers={Map.get(@viewers || %{}, "presence:spreadsheet:#{@file.id}", [])}
          current_user_id={@current_user.id}
          variant={:dots}
          topic={"presence:spreadsheet:#{@file.id}"}
        />
      </div>

      <div
        :if={@file}
        id={"spreadsheet-#{@file.id}"}
        phx-hook=".Univer"
        phx-update="ignore"
        data-adapter-url={~p"/assets/js/companions/spreadsheet/univer_adapter.js"}
        class="flex-1 min-h-0"
      >
      </div>

      <div
        :if={!@file}
        class="flex-1 flex items-center justify-center text-wb-text-muted"
      >
        <p>{gettext("File not found.")}</p>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Univer">
        // The Univer + SheetJS adapter (~18 MB) is built as a separate
        // esbuild entry and lazy-loaded the first time a SpreadsheetCompanion
        // mounts. We share one in-flight load across instances so opening
        // multiple .xlsx tabs does not refetch the bundle.
        function loadAdapter(url) {
          if (typeof window === "undefined") return Promise.reject(new Error("no window"));
          if (window.UniverAdapter) return Promise.resolve(window.UniverAdapter);
          if (window.__UniverAdapterPromise) return window.__UniverAdapterPromise;
          window.__UniverAdapterPromise = new Promise((resolve, reject) => {
            const script = document.createElement("script");
            script.src = url;
            script.async = true;
            script.onload = () => {
              if (window.UniverAdapter) {
                resolve(window.UniverAdapter);
              } else {
                reject(new Error("UniverAdapter not registered after script load"));
              }
            };
            script.onerror = (e) => reject(e);
            document.head.appendChild(script);
          });
          return window.__UniverAdapterPromise;
        }

        export default {
          mounted() {
            this.lib = null;
            this.adapter = null;
            this.pendingBinary = null;
            this.adapterLoading = loadAdapter(this.el.dataset.adapterUrl)
              .then((adapter) => {
                this.adapter = adapter;
                this.debouncedSave = adapter.debounce(() => {
                  if (!this.lib) return;
                  try {
                    const bytes = adapter.exportXlsx(this.lib);
                    let binary = "";
                    const chunkSize = 0x8000;
                    for (let i = 0; i < bytes.length; i += chunkSize) {
                      binary += String.fromCharCode.apply(
                        null,
                        bytes.subarray(i, i + chunkSize),
                      );
                    }
                    const b64 = btoa(binary);
                    this.pushEventTo(this.el, "spreadsheet:save", { binary: b64 });
                  } catch (err) {
                    console.error("Failed to export .xlsx from Univer", err);
                  }
                }, 800);
                if (this.pendingBinary) {
                  const b = this.pendingBinary;
                  this.pendingBinary = null;
                  this.renderBinary(b);
                }
              })
              .catch((err) => {
                console.error("Failed to load Univer adapter", err);
              });

            this.renderBinary = (binary) => {
              if (!this.adapter) {
                this.pendingBinary = binary;
                return;
              }
              const bytes = Uint8Array.from(atob(binary), c => c.charCodeAt(0));
              try {
                if (this.lib) {
                  this.lib.replaceWorkbook(bytes);
                } else {
                  this.lib = this.adapter.initUniverFromBinary(this.el, bytes, () => {
                    if (this.debouncedSave) this.debouncedSave();
                  });
                }
              } catch (err) {
                console.error("Failed to load .xlsx into Univer", err);
              }
            };

            this.handleEvent("spreadsheet:load", ({ binary }) => this.renderBinary(binary));

            this.handleEvent("spreadsheet:saved", () => {
              this.el.dispatchEvent(new CustomEvent("spreadsheet:saved", { bubbles: true }));
            });

            this.handleEvent("spreadsheet:updated_by_agent", () => {
              this.el.dispatchEvent(new CustomEvent("spreadsheet:updated_by_agent", { bubbles: true }));
            });

            this.handleEvent("spreadsheet:deleted", () => {
              this.el.dispatchEvent(new CustomEvent("spreadsheet:deleted", { bubbles: true }));
            });
          },
          destroyed() {
            if (this.lib && typeof this.lib.dispose === "function") {
              try { this.lib.dispose(); } catch (_e) { /* swallow */ }
            }
          }
        }
      </script>
    </section>
    """
  end

  defp save_indicator(assigns) do
    ~H"""
    <span class={[
      "text-xs",
      @state == :saved && "text-base-content/60",
      @state == :saving && "text-warning",
      @state == :error && "text-error"
    ]}>
      <%= case @state do %>
        <% :saved -> %>
          {gettext("Saved")}
        <% :saving -> %>
          {gettext("Saving...")}
        <% :error -> %>
          {gettext("Save failed")}
      <% end %>
    </span>
    """
  end

  defp push_load_event(socket, file, user) do
    case Magus.Files.read_binary(file, actor: user) do
      {:ok, binary} ->
        push_event(socket, "spreadsheet:load", %{
          binary: Base.encode64(binary),
          filename: file.name
        })

      {:error, _reason} ->
        socket
    end
  end
end
