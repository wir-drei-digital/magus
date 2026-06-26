defmodule MagusWeb.ChatLive.Components.ChatInput.ChatInputComponent do
  @moduledoc """
  LiveComponent for the chat input area.

  Reusable across main chat and thread pane via the `input_context` assign:
  - `:main` (default) — full-featured input with system prompt, tasks, selections, etc.
  - `:thread` — compact input with textarea, file uploads, model selector, submit button

  Handles:
  - Message form with textarea
  - Active system prompt indicator (main only)
  - Model selector
  - Context indicator
  - File attachments (drag-and-drop or click to upload)
  """
  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  @max_attachments 20
  @max_file_size 50_000_000

  attr :input_context, :atom,
    default: :main,
    doc: "Input context: :main for the main chat, :thread for thread pane."

  attr :dom_id_prefix, :string,
    default: "",
    doc: "Optional prefix for all DOM ids to avoid collisions when multiple instances coexist."

  attr :current_member_role, :atom,
    default: nil,
    doc: "Role of current user in multiplayer conversation. nil for non-multiplayer."

  attr :is_owner, :boolean,
    default: false,
    doc:
      "Whether the viewer owns the conversation. Gates the context-donut Clear/Compact/strategy controls (read-only donut for non-owners)."

  def render(assigns) do
    # Build the id prefix: thread context uses "thread-", callers may pass extra prefix.
    assigns =
      assign(
        assigns,
        :_id_prefix,
        assigns.dom_id_prefix <> if(assigns.input_context == :thread, do: "thread-", else: "")
      )

    ~H"""
    <div
      class="px-2 md:pb-4"
      id={"#{@_id_prefix}chat-input-area"}
      phx-hook="FocusMessageInput"
    >
      <%= if @current_member_role == :observer do %>
        <div class="flex items-center justify-center gap-2 py-3 px-4 rounded-lg bg-base-200 border border-base-300 text-base-content/50">
          <.icon name="lucide-eye" class="w-4 h-4 shrink-0" />
          <span class="text-sm">
            {gettext("You are viewing this conversation in read-only mode.")}
          </span>
        </div>
      <% else %>
        <%= if @input_context == :main do %>
          <%!-- Model Info Banner --%>
          <.model_info_banner model={get_selected_model(@models, @selected_model_id)} />

          <%!-- Modality Warning Banner --%>
          <.modality_warning_banner
            models={@models}
            selected_model_id={@selected_model_id}
            uploads={@uploads}
            context_resources={Map.get(assigns, :context_resources, [])}
          />

          <%!-- Active System Prompt Indicator --%>
          <.active_system_prompt_indicator :if={@active_system_prompt} prompt={@active_system_prompt} />
        <% end %>

        <div class="chat-input-card relative">
          <%= if @input_context == :main do %>
            <%!-- Task list (collapsible, above input) --%>
            <.live_component
              :if={Map.get(assigns, :conversation_tasks, []) != []}
              module={MagusWeb.ChatLive.Components.Tasks.TaskPaneComponent}
              id="task-list"
              tasks={Map.get(assigns, :conversation_tasks, [])}
              conversation_id={Map.get(assigns, :conversation_id)}
              current_user={Map.get(assigns, :current_user_for_tasks)}
            />
            <%!-- @Mention Autocomplete Dropdown --%>
            <.mention_dropdown
              :if={@show_mention_dropdown && @mention_suggestions != []}
              suggestions={@mention_suggestions}
              mention_index={@mention_index}
              myself={@myself}
            />

            <%!-- Draft Selection Badge --%>
            <.draft_selection_badge
              :if={Map.get(assigns, :draft_selection)}
              selection={Map.get(assigns, :draft_selection)}
              myself={@myself}
            />

            <%!-- PDF Selection Badge --%>
            <.pdf_selection_badge
              :if={Map.get(assigns, :pdf_selection)}
              selection={Map.get(assigns, :pdf_selection)}
            />

            <%!-- Service Selection Badge --%>
            <.service_selection_badge
              :if={Map.get(assigns, :service_selection)}
              selection={Map.get(assigns, :service_selection)}
            />

            <%!-- Brain Selection Badge --%>
            <.brain_selection_badge
              :if={Map.get(assigns, :brain_selection)}
              selection={Map.get(assigns, :brain_selection)}
            />

            <%!-- Message Selection Badges --%>
            <.message_selection_badges
              :if={Map.get(assigns, :message_selections, []) != []}
              selections={Map.get(assigns, :message_selections, [])}
            />
          <% end %>

          <% ctx_resources = Map.get(assigns, :context_resources, []) %>
          <%!-- Attached Files Preview (combined: context resources + uploads) --%>
          <.attached_files_preview
            context_resources={ctx_resources}
            upload_entries={@uploads.attachments.entries}
            upload_errors={fn entry -> upload_errors(@uploads.attachments, entry) end}
            upload_rejections={@upload_rejections}
            myself={@myself}
          />

          <%!-- Message Form with File Drop Zone --%>
          <.form
            :let={form}
            for={@message_form}
            phx-change="validate_message"
            phx-debounce="300"
            phx-submit="send_message_with_attachments"
            phx-target={@myself}
          >
            <div
              class="relative"
              phx-drop-target={@uploads.attachments.ref}
              id={"#{@_id_prefix}chat-drop-zone"}
              phx-hook="ChatDropZone"
            >
              <%!-- Textarea area --%>
              <div class="px-3 pt-2">
                <textarea
                  name={form[:text].name}
                  id={"#{@_id_prefix}chat-textarea"}
                  phx-hook="ChatTextarea"
                  phx-keyup="user_typing"
                  phx-target={@myself}
                  phx-debounce="500"
                  data-target={@myself}
                  data-conversation-id={@conversation_id || "new"}
                  placeholder={
                    if @input_context == :thread,
                      do: gettext("Message thread... (Enter to send)"),
                      else: gettext("Type your message... (Enter to send, Shift+Enter for new line)")
                  }
                  class={[
                    "w-full bg-transparent border-none outline-none resize-none text-sm placeholder:text-base-content/40 py-2 max-h-[500px] overflow-y-auto",
                    if(@input_context == :thread,
                      do: "min-h-[2.5rem]",
                      else: "min-h-[2.5rem] md:min-h-[96px]"
                    )
                  ]}
                  autocomplete="off"
                  autofocus
                >{@text_value}</textarea>
                <input
                  :if={@conversation_id}
                  type="hidden"
                  name={form[:conversation_id].name}
                  value={@conversation_id}
                />
                <input
                  :if={
                    @input_context == :main && !@conversation_id && Map.get(assigns, :last_folder_id)
                  }
                  type="hidden"
                  name={form[:folder_id].name}
                  value={Map.get(assigns, :last_folder_id)}
                />
                <%!-- Hidden input for chat mode --%>
                <input type="hidden" name={form[:mode].name} value={@chat_mode} />
                <%!-- Hidden input for selected model --%>
                <input type="hidden" name={form[:selected_model_id].name} value={@selected_model_id} />
                <%!-- Hidden input for input context --%>
                <input type="hidden" name={form[:input_context].name} value={@input_context} />
              </div>

              <%!-- Bottom row: buttons, mode toggles, model selector, context indicator --%>
              <div class="flex items-center gap-2 px-2 pb-2">
                <%!-- Action menu (+) button --%>
                <.action_menu
                  uploads={@uploads}
                  slash_commands={Map.get(assigns, :slash_commands, [])}
                  myself={@myself}
                  input_context={@input_context}
                />

                <%!-- Model Selector with Mode Toggles --%>
                <div class="flex-1 flex items-center gap-4 flex-wrap">
                  <.live_component
                    module={MagusWeb.ChatLive.Components.ChatInput.ModelSelectorComponent}
                    id={"#{@_id_prefix}model-selector"}
                    input_context={@input_context}
                    models={@models}
                    selected_model_id={@selected_model_id}
                    chat_mode={@chat_mode}
                    current_user={@current_user}
                    conversation={Map.get(assigns, :conversation)}
                    selected_chat_model_id={Map.get(assigns, :selected_chat_model_id)}
                    selected_image_model_id={Map.get(assigns, :selected_image_model_id)}
                    selected_video_model_id={Map.get(assigns, :selected_video_model_id)}
                    image_generation_settings={Map.get(assigns, :image_generation_settings, %{})}
                    video_generation_settings={Map.get(assigns, :video_generation_settings, %{})}
                    image_generation_enabled={Map.get(assigns, :image_generation_enabled, true)}
                    video_generation_enabled={Map.get(assigns, :video_generation_enabled, true)}
                  />
                </div>

                <%!-- Context-window donut (display-only for non-owners) --%>
                <.live_component
                  module={MagusWeb.ChatLive.Components.ChatInput.ContextIndicatorComponent}
                  id={"#{@_id_prefix}context-donut"}
                  context_window={@context_window}
                  model={get_selected_model(@models, @selected_model_id)}
                  is_owner={Map.get(assigns, :is_owner, false)}
                />

                <%!-- Submit/Stop button --%>
                <% uploads_in_progress =
                  Enum.any?(@uploads.attachments.entries, fn e -> e.progress < 100 end) %>
                <% modality_mismatch =
                  has_modality_mismatch?(
                    @models,
                    @selected_model_id,
                    @uploads.attachments.entries,
                    ctx_resources
                  ) %>
                <% has_rejections = @upload_rejections != [] %>
                <% compacting = compaction_in_progress?(@context_window) %>
                <% send_disabled =
                  uploads_in_progress or modality_mismatch or has_rejections or compacting %>
                <button
                  type="submit"
                  data-role="send-message"
                  data-send-disabled={to_string(send_disabled)}
                  disabled={send_disabled}
                  class={[
                    "btn btn-circle btn-sm border-none shrink-0",
                    if(send_disabled, do: "btn-disabled opacity-50", else: "btn-primary")
                  ]}
                  title={
                    cond do
                      uploads_in_progress ->
                        gettext("Waiting for uploads...")

                      modality_mismatch ->
                        gettext("Model doesn't support image input")

                      has_rejections ->
                        gettext("Remove unsupported files to send")

                      compacting ->
                        gettext("Compacting context, please wait...")

                      Map.get(assigns, :waiting_for_response, false) or
                          Map.get(assigns, :is_streaming, false) ->
                        gettext("Queue message")

                      true ->
                        gettext("Send message")
                    end
                  }
                >
                  <.icon
                    :if={!uploads_in_progress}
                    name="lucide-arrow-right"
                    class="w-4 h-4"
                  />
                  <span
                    :if={uploads_in_progress}
                    class="loading loading-spinner loading-xs"
                  />
                </button>
                <button
                  :if={
                    Map.get(assigns, :waiting_for_response, false) or
                      Map.get(assigns, :is_streaming, false)
                  }
                  type="button"
                  phx-click="stop_response"
                  class="btn btn-circle btn-sm border-none shrink-0 btn-primary"
                  title={gettext("Cancel response")}
                >
                  <.icon name="lucide-square" class="w-4 h-4" />
                </button>
              </div>

              <%!-- Drop Overlay --%>
              <div
                id={"#{@_id_prefix}drop-overlay"}
                class="hidden absolute inset-0 bg-primary/10 border-2 border-dashed border-primary rounded-xl flex items-center justify-center pointer-events-none"
              >
                <span class="text-primary font-medium">{gettext("Drop files to attach")}</span>
              </div>
            </div>
          </.form>
        </div>
      <% end %>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     |> assign(:text_value, "")
     |> assign(:show_mention_dropdown, false)
     |> assign(:mention_suggestions, [])
     |> assign(:mention_index, 0)
     |> assign(:upload_rejections, [])
     |> assign(:show_action_menu, false)
     |> allow_upload(:attachments,
       accept: :any,
       max_entries: @max_attachments,
       max_file_size: @max_file_size,
       auto_upload: true
     )}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign_new(:context_window, fn -> nil end)
     |> assign_new(:is_owner, fn -> false end)
     |> assign(assigns)}
  end

  def handle_event("validate_message", %{"form" => params}, socket) do
    notify_parent({:validate_message, params})
    text_value = params["text"] || ""

    {:noreply,
     socket
     |> assign(:text_value, text_value)
     |> validate_upload_entries()}
  end

  # Sync text value immediately on input (not debounced) to preserve across re-renders
  def handle_event("sync_text", %{"value" => value}, socket) do
    {:noreply, assign(socket, :text_value, value)}
  end

  def handle_event("remove_attachment", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> cancel_upload(:attachments, ref)
     |> validate_upload_entries()}
  end

  def handle_event("send_message_with_attachments", %{"form" => params}, socket) do
    uploads_in_progress =
      Enum.any?(socket.assigns.uploads.attachments.entries, fn e -> e.progress < 100 end)

    ctx_resources = Map.get(socket.assigns, :context_resources, [])

    modality_mismatch =
      has_modality_mismatch?(
        socket.assigns.models,
        socket.assigns.selected_model_id,
        socket.assigns.uploads.attachments.entries,
        ctx_resources
      )

    has_rejections = socket.assigns.upload_rejections != []
    compacting = compaction_in_progress?(Map.get(socket.assigns, :context_window))

    cond do
      uploads_in_progress -> {:noreply, socket}
      modality_mismatch -> {:noreply, socket}
      has_rejections -> {:noreply, socket}
      compacting -> {:noreply, socket}
      true -> do_send_message_with_attachments(socket, params)
    end
  end

  def handle_event("user_typing", %{"value" => value}, socket) do
    broadcast_typing_state(socket, String.length(value) > 0)
    {:noreply, socket}
  end

  # Slash command injection from action menu
  def handle_event("inject_slash_command", %{"name" => name}, socket) do
    {:noreply, push_event(socket, "insert_text", %{text: "/#{name} ", mode: "prepend"})}
  end

  # @Mention autocomplete events

  def handle_event("mention_search", %{"query" => query}, socket) do
    agents = Map.get(socket.assigns, :available_agents, [])
    query_down = String.downcase(query)

    suggestions =
      agents
      |> Enum.filter(fn a ->
        String.starts_with?(a.handle, query_down) ||
          String.contains?(String.downcase(a.name), query_down)
      end)
      |> Enum.take(5)

    {:noreply,
     socket
     |> assign(:mention_suggestions, suggestions)
     |> assign(:show_mention_dropdown, suggestions != [])
     |> assign(:mention_index, 0)}
  end

  def handle_event("mention_close", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_mention_dropdown, false)
     |> assign(:mention_suggestions, [])
     |> assign(:mention_index, 0)}
  end

  def handle_event("mention_navigate", %{"direction" => direction}, socket) do
    count = length(socket.assigns.mention_suggestions)

    new_index =
      case direction do
        "up" -> rem(socket.assigns.mention_index - 1 + count, max(count, 1))
        "down" -> rem(socket.assigns.mention_index + 1, max(count, 1))
        _ -> socket.assigns.mention_index
      end

    {:noreply, assign(socket, :mention_index, new_index)}
  end

  def handle_event("mention_select", %{"handle" => handle}, socket) do
    # When Enter/Tab is pressed, handle is "" — pick the highlighted item
    selected_handle =
      if handle == "" do
        case Enum.at(socket.assigns.mention_suggestions, socket.assigns.mention_index) do
          nil -> nil
          agent -> agent.handle
        end
      else
        handle
      end

    socket =
      socket
      |> assign(:show_mention_dropdown, false)
      |> assign(:mention_suggestions, [])
      |> assign(:mention_index, 0)

    socket =
      if selected_handle,
        do: push_event(socket, "mention_insert", %{handle: selected_handle}),
        else: socket

    {:noreply, socket}
  end

  # Private helpers

  defp do_send_message_with_attachments(socket, params) do
    user = socket.assigns.current_user
    entries = socket.assigns.uploads.attachments.entries
    files = Enum.map(entries, &%{name: &1.client_name, size: &1.client_size})

    # Pre-validate storage limits before consuming uploads
    case Magus.Usage.PolicyEnforcer.check_file_uploads(user, files) do
      {:ok, :allowed} ->
        do_consume_and_send(socket, params)

      {:error, message} ->
        notify_parent({:flash, :error, message})
        {:noreply, socket}
    end
  end

  defp validate_upload_entries(socket) do
    max_bytes = Map.get(socket.assigns, :max_upload_bytes)
    entries = socket.assigns.uploads.attachments.entries

    {socket, rejections} =
      Enum.reduce(entries, {socket, []}, fn entry, {sock, rejects} ->
        if max_bytes && entry.client_size > max_bytes do
          limit_mb = Float.round(max_bytes / 1_000_000, 1)

          {cancel_upload(sock, :attachments, entry.ref),
           [
             gettext("%{name}: File too large (max %{limit} MB)",
               name: entry.client_name,
               limit: limit_mb
             )
             | rejects
           ]}
        else
          {sock, rejects}
        end
      end)

    assign(socket, :upload_rejections, Enum.reverse(rejections))
  end

  defp do_consume_and_send(socket, params) do
    # Create Files.File records for uploaded files
    # This unifies the flow: both uploads and dragged files become Files.File
    # Associate with conversation if one exists
    conversation_id = socket.assigns.conversation_id

    results =
      consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
        content = File.read!(path)

        # Create the Files.File immediately, associated with conversation if available
        opts =
          [actor: socket.assigns.current_user]
          |> then(fn opts ->
            if conversation_id,
              do: Keyword.put(opts, :conversation_id, conversation_id),
              else: opts
          end)

        case Magus.Files.Upload.create_file_from_upload(
               content,
               entry.client_name,
               entry.client_type,
               byte_size(content),
               opts
             ) do
          {:ok, file} -> {:ok, {:ok, file}}
          {:error, reason} -> {:ok, {:error, entry.client_name, reason}}
        end
      end)

    {successes, failures} =
      Enum.split_with(results, fn
        {:ok, _file} -> true
        {:error, _name, _reason} -> false
      end)

    uploaded_files = Enum.map(successes, fn {:ok, file} -> file end)

    if failures != [] do
      failed_names = Enum.map_join(failures, ", ", fn {:error, name, _} -> name end)

      notify_parent(
        {:flash, :error,
         gettext("Could not process: %{names}. Unsupported file type.", names: failed_names)}
      )

      # Block send — keep text in input so the user can retry without the bad file
      {:noreply, socket}
    else
      broadcast_typing_state(socket, false)
      input_context = socket.assigns[:input_context] || :main

      case input_context do
        :thread ->
          notify_parent({:send_thread_message_with_resources, params, uploaded_files})

        _ ->
          notify_parent({:send_message_with_resources, params, uploaded_files})
      end

      {:noreply, assign(socket, :text_value, "")}
    end
  end

  attr :model, :map, default: nil

  defp model_info_banner(assigns) do
    ~H"""
    <div
      :if={@model && @model.info}
      class="mb-2 px-3 py-2 rounded-lg bg-info/10 border border-info/20 text-info text-sm flex items-start gap-2 backdrop-blur-md"
    >
      <.icon name="lucide-info" class="w-5 h-5 shrink-0 mt-0.5" />
      <span>{@model.info}</span>
    </div>
    """
  end

  attr :prompt, :map, required: true

  defp active_system_prompt_indicator(assigns) do
    ~H"""
    <div class="mb-2 px-3 py-2 rounded-lg bg-primary/10 border border-primary/30 text-sm flex items-center gap-2 backdrop-blur-md">
      <.icon name="lucide-id-card" class="w-5 h-5 text-primary shrink-0" />
      <span class="font-medium">{@prompt.name}</span>
      <span :if={@prompt.model} class="text-base-content/60 text-xs flex items-center gap-1">
        <.icon name="lucide-cpu" class="w-3 h-3" />
        {@prompt.model.name}
      </span>
    </div>
    """
  end

  defp get_selected_model(models, selected_id) do
    Enum.find(models, fn m -> m.id == selected_id end)
  end

  attr :models, :list, required: true
  attr :selected_model_id, :any, required: true
  attr :uploads, :any, required: true
  attr :context_resources, :list, required: true

  defp modality_warning_banner(assigns) do
    show_warning =
      has_modality_mismatch?(
        assigns.models,
        assigns.selected_model_id,
        assigns.uploads.attachments.entries,
        assigns.context_resources
      )

    assigns = assign(assigns, :show_warning, show_warning)

    ~H"""
    <div
      :if={@show_warning}
      class="mb-2 px-3 py-2 rounded-lg bg-warning/10 border border-warning/20 text-warning text-sm flex items-start gap-2 backdrop-blur-md"
    >
      <.icon name="lucide-alert-triangle" class="w-5 h-5 shrink-0 mt-0.5" />
      <span>
        {gettext(
          "The selected model does not support image input. Change the model or remove image attachments."
        )}
      </span>
    </div>
    """
  end

  # Send-lock: true while a compaction is in flight for this conversation.
  # nil-safe (no window -> not compacting); :idle/:failed do not block.
  defp compaction_in_progress?(nil), do: false

  defp compaction_in_progress?(context_window),
    do: Map.get(context_window, :compaction_status) in [:pending, :running]

  defp has_modality_mismatch?(models, selected_model_id, upload_entries, context_resources) do
    has_image =
      Enum.any?(upload_entries, fn e -> String.starts_with?(e.client_type, "image/") end) or
        Enum.any?(context_resources, fn r -> r.type == :image end)

    if has_image and selected_model_id do
      case Enum.find(models, fn m -> m.id == selected_model_id end) do
        nil -> false
        model -> "image" not in (model.input_modalities || ["text"])
      end
    else
      false
    end
  end

  defp file_icon(mime_type) do
    cond do
      # Documents (PDF, Office, OpenDocument, EPUB)
      String.contains?(mime_type, "pdf") ->
        "lucide-file"

      String.contains?(mime_type, "word") or String.contains?(mime_type, "document") ->
        "lucide-file"

      String.contains?(mime_type, "sheet") or String.contains?(mime_type, "excel") ->
        "lucide-table"

      String.contains?(mime_type, "presentation") or String.contains?(mime_type, "powerpoint") ->
        "lucide-presentation"

      String.contains?(mime_type, "epub") ->
        "lucide-book-open"

      mime_type == "message/rfc822" or String.contains?(mime_type, "outlook") ->
        "lucide-mail"

      String.starts_with?(mime_type, "image/") ->
        "lucide-image"

      String.starts_with?(mime_type, "video/") ->
        "lucide-film"

      true ->
        "lucide-file-text"
    end
  end

  defp resource_icon(:document), do: "lucide-file"
  defp resource_icon(:text), do: "lucide-file-text"
  defp resource_icon(:image), do: "lucide-image"
  defp resource_icon(:video), do: "lucide-film"
  defp resource_icon(:email), do: "lucide-mail"
  defp resource_icon(_), do: "lucide-file"

  defp error_to_string(:too_large), do: gettext("File too large (max 50MB)")
  defp error_to_string(:not_accepted), do: gettext("File type not accepted")

  defp error_to_string(:too_many_files),
    do: gettext("Too many files (max %{count})", count: @max_attachments)

  defp error_to_string(err), do: to_string(err)

  attr :suggestions, :list, required: true
  attr :mention_index, :integer, default: 0
  attr :myself, :any, required: true

  defp mention_dropdown(assigns) do
    ~H"""
    <div
      id="mention-dropdown"
      class="absolute bottom-full left-0 right-0 mb-1 mx-2 z-50 bg-base-100 border border-base-300 rounded-lg shadow-lg overflow-hidden"
      phx-click-away="mention_close"
      phx-target={@myself}
    >
      <div class="px-2 py-1.5 border-b border-base-200 text-xs text-base-content/50 font-medium">
        {gettext("Mention an agent")}
      </div>
      <ul
        class="py-1 max-h-52 overflow-y-auto"
        id="mention-list"
        phx-hook="MentionDropdown"
      >
        <li :for={{agent, idx} <- Enum.with_index(@suggestions)}>
          <button
            type="button"
            id={"mention-item-#{idx}"}
            phx-click="mention_select"
            phx-value-handle={agent.handle}
            phx-target={@myself}
            data-active={if(idx == @mention_index, do: "true")}
            class={[
              "flex items-center gap-2.5 w-full px-3 py-2 text-left transition-colors",
              if(idx == @mention_index,
                do: "bg-primary/10 text-primary",
                else: "hover:bg-base-200"
              )
            ]}
          >
            <span
              :if={agent.icon}
              class="w-7 h-7 rounded-full bg-base-200 flex items-center justify-center text-base shrink-0"
            >
              {agent.icon}
            </span>
            <span
              :if={!agent.icon}
              class="w-7 h-7 rounded-full bg-primary/10 flex items-center justify-center text-xs text-primary font-semibold shrink-0"
            >
              {String.first(agent.name)}
            </span>
            <div class="flex flex-col min-w-0">
              <span class="font-medium text-sm truncate">{agent.name}</span>
              <span class="text-xs text-base-content/50">@{agent.handle}</span>
            </div>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # Action menu (+) button with dropdown for attach file + slash commands
  attr :uploads, :any, required: true
  attr :slash_commands, :list, required: true
  attr :myself, :any, required: true
  attr :input_context, :atom, default: :main

  defp action_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-top shrink-0">
      <button
        type="button"
        tabindex="0"
        class="btn btn-ghost btn-sm btn-circle text-base-content/60 hover:text-base-content hover:bg-base-300"
        title={gettext("Actions")}
      >
        <.icon name="lucide-plus" class="w-5 h-5" />
      </button>
      <ul
        tabindex="0"
        class="dropdown-content z-50 menu menu-sm bg-base-200 border border-base-300 rounded-lg shadow-lg w-72 mb-2"
      >
        <%!-- Attach file --%>
        <li>
          <label class="cursor-pointer">
            <.live_file_input upload={@uploads.attachments} class="hidden" />
            <.icon name="lucide-paperclip" class="w-4 h-4" />
            {gettext("Attach file")}
          </label>
        </li>
        <%= if @input_context == :main && @slash_commands != [] do %>
          <li class="menu-divider"></li>
          <%!-- Slash commands --%>
          <li :for={cmd <- @slash_commands}>
            <button
              type="button"
              phx-click="inject_slash_command"
              phx-value-name={cmd.name}
              phx-target={@myself}
            >
              <.icon :if={cmd[:icon]} name={cmd[:icon]} class="w-4 h-4" />
              <span :if={!cmd[:icon]} class="w-4 h-4" />
              {Magus.Agents.SlashCommands.title(cmd[:title])}
              <span class="text-base-content/50 font-normal ml-auto">/{cmd.name}</span>
            </button>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  defp broadcast_typing_state(socket, is_typing) do
    conversation = socket.assigns[:conversation]

    if conversation && MagusWeb.ChatLive.Helpers.collaborative?(conversation) do
      user = socket.assigns.current_user

      Magus.Endpoint.broadcast(
        "chat:typing:#{conversation.id}",
        "user_typing",
        %{
          user_id: user.id,
          user_name: user.display_name || to_string(user.email),
          avatar_path: Map.get(user, :avatar_path),
          email: to_string(user.email),
          is_typing: is_typing
        }
      )
    end
  end

  # Draft selection badge (appears when user selects text in the draft pane)
  attr :selection, :map, required: true
  attr :myself, :any, required: true

  defp draft_selection_badge(assigns) do
    truncated =
      if String.length(assigns.selection.text) > 50,
        do: String.slice(assigns.selection.text, 0, 50) <> "...",
        else: assigns.selection.text

    assigns = assign(assigns, :truncated, truncated)

    ~H"""
    <div class="mb-2 flex">
      <div class="flex items-center gap-2 bg-primary/10 border border-primary/30 rounded-lg px-3 py-1.5 text-sm">
        <.icon name="lucide-text-select" class="w-4 h-4 text-primary shrink-0" />
        <span class="text-primary/70 font-mono text-xs">
          {gettext("~line %{line}", line: @selection.hint_line)}
        </span>
        <span class="truncate max-w-48">{@truncated}</span>
        <button
          type="button"
          phx-click="clear_draft_selection"
          class="btn btn-ghost btn-xs btn-circle"
        >
          <.icon name="lucide-x" class="w-3 h-3" />
        </button>
      </div>
    </div>
    """
  end

  # PDF selection badge (appears when user selects a region in the PDF pane)
  attr :selection, :map, required: true

  defp pdf_selection_badge(assigns) do
    truncated_text =
      case assigns.selection.text do
        text when is_binary(text) and text != "" ->
          if String.length(text) > 40,
            do: String.slice(text, 0, 40) <> "...",
            else: text

        _ ->
          nil
      end

    assigns = assign(assigns, :truncated_text, truncated_text)

    ~H"""
    <div class="px-3 pt-2">
      <div class="flex items-center gap-2 bg-primary/10 border border-primary/30 rounded-lg px-3 py-1.5 text-sm w-fit">
        <img
          src={@selection.image}
          class="w-12 h-12 object-contain rounded border border-base-300"
        />
        <div class="min-w-0">
          <span class="text-base-content/60 font-mono text-xs">
            {gettext("page %{page}", page: @selection.page)}
          </span>
          <span :if={@truncated_text} class="truncate max-w-48 block text-xs">
            {@truncated_text}
          </span>
        </div>
        <button
          type="button"
          phx-click="clear_pdf_selection"
          class="btn btn-ghost btn-xs btn-circle"
        >
          <.icon name="lucide-x" class="w-3 h-3" />
        </button>
      </div>
    </div>
    """
  end

  # Service selection badge (appears when user captures a screenshot from the sandbox pane)
  attr :selection, :map, required: true

  defp service_selection_badge(assigns) do
    ~H"""
    <div class="px-3 pt-2">
      <div class="flex items-center gap-2 bg-primary/10 border border-primary/30 rounded-lg px-3 py-1.5 text-sm w-fit">
        <img
          src={@selection.image}
          class="w-12 h-12 object-contain rounded border border-base-300"
        />
        <div class="min-w-0">
          <span class="text-base-content/60 font-mono text-xs">
            {gettext("Service Preview")}
          </span>
          <span
            :if={@selection.service_name && @selection.service_name != "service"}
            class="truncate max-w-48 block text-xs"
          >
            {@selection.service_name}
          </span>
        </div>
        <button
          type="button"
          phx-click="clear_service_selection"
          class="btn btn-ghost btn-xs btn-circle"
        >
          <.icon name="lucide-x" class="w-3 h-3" />
        </button>
      </div>
    </div>
    """
  end

  # Brain selection badge (appears when user selects text in the brain editor)
  attr :selection, :map, required: true

  defp brain_selection_badge(assigns) do
    ~H"""
    <div class="px-3 pt-2">
      <div class="flex items-center gap-2 bg-primary/10 border border-primary/30 rounded-lg px-3 py-1.5 text-sm w-fit">
        <.icon name="lucide-brain" class="w-4 h-4 text-primary flex-shrink-0" />
        <div class="min-w-0">
          <span class="text-base-content/60 font-mono text-xs block">
            {@selection["page_title"]}
          </span>
          <span class="truncate max-w-48 block text-xs">
            {String.slice(@selection["text"] || "", 0, 60)}
          </span>
        </div>
        <button
          type="button"
          phx-click="brain_text_cleared"
          class="btn btn-ghost btn-xs btn-circle"
        >
          <.icon name="lucide-x" class="w-3 h-3" />
        </button>
      </div>
    </div>
    """
  end

  # Message selection badges (appears when user selects text in message bubbles)
  attr :selections, :list, required: true

  defp message_selection_badges(assigns) do
    indexed =
      assigns.selections
      |> Enum.with_index()
      |> Enum.map(fn {sel, idx} ->
        truncated =
          if String.length(sel.text) > 50,
            do: String.slice(sel.text, 0, 50) <> "...",
            else: sel.text

        role_label =
          if sel.role == "user",
            do: gettext("your message"),
            else: gettext("agent message")

        %{index: idx, truncated: truncated, role_label: role_label}
      end)

    assigns = assign(assigns, :indexed, indexed)

    ~H"""
    <div class="mb-2 flex flex-wrap gap-1">
      <div
        :for={item <- @indexed}
        class="flex items-center gap-2 bg-primary/10 border border-primary/30 rounded-lg px-3 py-1.5 text-sm"
      >
        <.icon name="lucide-message-square-quote" class="w-4 h-4 text-primary shrink-0" />
        <span class="text-primary/70 text-xs">{item.role_label}</span>
        <span class="truncate max-w-48">{item.truncated}</span>
        <button
          type="button"
          phx-click="clear_message_selection"
          phx-value-index={item.index}
          class="btn btn-ghost btn-xs btn-circle"
        >
          <.icon name="lucide-x" class="w-3 h-3" />
        </button>
      </div>
    </div>
    """
  end

  # Combined preview for context resources (from Memory sidebar) and upload entries
  attr :context_resources, :list, required: true
  attr :upload_entries, :list, required: true
  attr :upload_errors, :any, required: true
  attr :upload_rejections, :list, default: []
  attr :myself, :any, required: true

  defp attached_files_preview(assigns) do
    has_items =
      Enum.any?(assigns.context_resources) or Enum.any?(assigns.upload_entries) or
        Enum.any?(assigns.upload_rejections)

    assigns = assign(assigns, :has_items, has_items)

    ~H"""
    <div :if={@has_items} class="mb-2 flex flex-wrap gap-2">
      <%!-- Context Resources (dragged from Memory sidebar) --%>
      <div
        :for={resource <- @context_resources}
        class="flex items-center gap-2 bg-info/10 border border-info/30 rounded-lg px-3 py-1.5 text-sm"
      >
        <.icon name={resource_icon(resource.type)} class="w-4 h-4 text-info" />
        <span class="truncate max-w-32">{resource.name}</span>
        <button
          type="button"
          phx-click="remove_context_resource"
          phx-value-id={resource.id}
          class="btn btn-ghost btn-xs btn-circle"
        >
          <.icon name="lucide-x" class="w-3 h-3" />
        </button>
      </div>

      <%!-- Upload Entries (attached via upload button or drop) --%>
      <div
        :for={entry <- @upload_entries}
        class="flex items-center gap-2 bg-base-200 rounded-lg px-3 py-1.5 text-sm"
      >
        <.icon name={file_icon(entry.client_type)} class="w-4 h-4 text-base-content/70" />
        <span class="truncate max-w-32">{entry.client_name}</span>
        <span
          :if={entry.progress > 0 and entry.progress < 100}
          class="text-xs text-base-content/50"
        >
          {entry.progress}%
        </span>
        <button
          type="button"
          phx-click="remove_attachment"
          phx-value-ref={entry.ref}
          phx-target={@myself}
          class="btn btn-ghost btn-xs btn-circle"
        >
          <.icon name="lucide-x" class="w-3 h-3" />
        </button>
      </div>

      <%!-- Upload errors --%>
      <%= for entry <- @upload_entries, {err, _} <- @upload_errors.(entry) do %>
        <p class="text-error text-xs w-full">
          {entry.client_name}: {error_to_string(err)}
        </p>
      <% end %>

      <%!-- Upload rejections (file too large or unsupported type) --%>
      <p :for={rejection <- @upload_rejections} class="text-error text-xs w-full">
        {rejection}
      </p>
    </div>
    """
  end
end
