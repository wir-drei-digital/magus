defmodule MagusWeb.Workbench.Resources.BrainPageView do
  @moduledoc """
  LiveView that renders a brain page inside a workbench tab as primary OR
  as a tab-bound companion. Wraps `BrainPaneComponent` without forking.

  Session:
    - `"page_id"` — UUID of the brain page
    - `"user_id"` — UUID of the current user
    - `"tab_id"` — workbench tab id
    - `"role"` — optional "primary" | "companion" hint
  """
  use MagusWeb, :live_view

  on_mount Magus.Presence

  alias Magus.Brain
  alias Magus.Brain.BodyParser
  alias Magus.Brain.Page.Errors.VersionConflict
  alias MagusWeb.ChatLive.Components.Brain.BrainPaneComponent

  @max_file_picker_inserts 50

  # PubSub topic for file events whose status changes should refresh the
  # editor. Matches the topics emitted by `Magus.Files.File`'s `pub_sub`
  # block (user-scoped) and the `BroadcastWorkspaceEvent` change
  # (workspace-scoped). A brain only contains files from its own scope, so
  # one subscription per page suffices.
  defp file_scope_topic(%{workspace_id: nil}, %{id: user_id}),
    do: "files:files:#{user_id}"

  defp file_scope_topic(%{workspace_id: ws_id}, _user) when not is_nil(ws_id),
    do: "workspaces:#{ws_id}:files"

  @impl true
  def mount(_params, session, socket) do
    page_id = session["page_id"]
    user_id = session["user_id"]
    tab_id = session["tab_id"]
    role = session["role"] || "primary"

    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    # Every authorized brain-resource read routes through
    # `BrainAccessFilter`, which resolves the actor's accessible brain ids
    # with ~5 uncached queries per call. Wrapping the whole load pass in a
    # request-scoped cache collapses those repeated resolutions into a
    # single one for this mount (the cache is torn down when the scope
    # ends, so authorization stays exactly correct — see
    # `BrainAccessFilter.with_request_cache/1`).
    result =
      Magus.Brain.Checks.BrainAccessFilter.with_request_cache(fn ->
        load_page_context(page_id, user)
      end)

    case result do
      {:ok, brain, page} ->
        if connected?(socket) do
          Magus.Endpoint.subscribe(Brain.Topics.brain(brain.id))
          Magus.Endpoint.subscribe(Brain.Topics.page(brain.id, page.id))
          Magus.Endpoint.subscribe(file_scope_topic(brain, user))

          # Listen for companion open/close on our tab so we can hide the
          # "Open chat" button while a companion is already attached.
          if tab_id do
            Phoenix.PubSub.subscribe(
              Magus.PubSub,
              MagusWeb.Workbench.Signals.tab_topic(tab_id)
            )
          end
        end

        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:brain, brain)
          |> assign_page(page)
          |> assign(:brain_pages, [])
          |> assign(:brain_pages_json, pages_json([]))
          |> assign(:page_sources, [])
          |> assign(:page_sources_loaded?, false)
          |> assign(:related_pages, [])
          |> assign(:related_pages_loaded?, false)
          |> assign(:page_versions, [])
          |> assign(:page_versions_loaded?, false)
          |> assign(:viewing_version, nil)
          |> assign(:tab_id, tab_id)
          |> assign(:role, role)
          |> assign(:companion_present?, session["has_companion"] == true)
          |> assign(:brain_file_picker_open?, false)
          |> assign(:not_found, false)
          |> Magus.Presence.track(:page, page.id)

        socket =
          if connected?(socket) do
            start_async(socket, :load_brain_pages, fn ->
              load_sibling_pages(brain.id, user)
            end)
          else
            socket
          end

        {:ok, socket}

      :error ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:tab_id, tab_id)
         |> assign(:role, role)
         |> assign(:brain_file_picker_open?, false)
         |> assign(:not_found, true)
         |> assign(:page_id, page_id)}
    end
  end

  defp load_page_context(page_id, user) do
    case Brain.get_page(page_id,
           actor: user,
           load: [:prosemirror, brain: [:is_shared_to_workspace]]
         ) do
      {:ok, page} when not is_nil(page.brain) ->
        {:ok, page.brain, page}

      _ ->
        :error
    end
  end

  # The connected-mount sibling list feeds ONLY the `[[wikilink]]` resolver
  # (`brain:open_page_ref`, which matches on `&1.title` / `&1.id`) and
  # the editor hook page-ref autocomplete (which keeps just `%{id, title}`).
  # The `:for_brain` action otherwise selects every column including the full
  # markdown `body`, so a brain with many large pages would pull all bodies
  # into memory and into the `data-pages` JSON attribute. Select only the two
  # columns actually consumed.
  defp load_sibling_pages(brain_id, user) do
    require Ash.Query

    case Magus.Brain.Page
         |> Ash.Query.for_read(:for_brain, %{brain_id: brain_id}, actor: user)
         |> Ash.Query.select([:id, :title])
         |> Ash.read() do
      {:ok, pages} -> pages
      _ -> []
    end
  end

  defp assign_page(socket, page) do
    socket
    |> assign(:page, page)
    |> assign(:editor_content_json, editor_content_json(page))
  end

  defp serialize_pages(pages) when is_list(pages) do
    Enum.map(pages, fn page -> %{id: page.id, title: page.title || "Untitled"} end)
  end

  defp serialize_pages(_), do: []

  defp pages_json(pages) do
    pages
    |> serialize_pages()
    |> Jason.encode!()
  end

  # The editor hydrates from ProseMirror JSON. Prefer the loaded `:prosemirror`
  # calculation, but fall back to converting the body on the fly when the page
  # was assigned without the calc loaded (e.g. a title rename result or a
  # `page.updated` broadcast record) — otherwise `Jason.encode!` would crash on
  # an `%Ash.NotLoaded{}`.
  defp editor_content_json(page) do
    page
    |> editor_prosemirror_doc()
    |> Jason.encode!()
  end

  defp editor_prosemirror_doc(%{prosemirror: %Ash.NotLoaded{}} = page), do: doc_from_body(page)
  defp editor_prosemirror_doc(%{prosemirror: nil} = page), do: doc_from_body(page)
  defp editor_prosemirror_doc(%{prosemirror: doc}) when is_map(doc), do: doc
  defp editor_prosemirror_doc(page), do: doc_from_body(page)

  defp doc_from_body(%{body: body}) when is_binary(body),
    do: Magus.Brain.ProseMirrorProfile.body_to_prosemirror(body)

  defp doc_from_body(_), do: Magus.Markdown.ProseMirror.default_doc()

  defp reload_brain(brain, user) do
    case Brain.get_brain(brain.id, actor: user, load: [:is_shared_to_workspace]) do
      {:ok, fresh} -> fresh
      _ -> brain
    end
  end

  # ----------------------------------------------------------------------------
  # Bottom-panel feeds (Sources / Related / Activity)
  #
  # Data comes from the Phase B/C resources: `Source` (brain-scoped URLs),
  # `PageLink` (`[[wiki]]` backlinks), and `Page.Version` (per-page audit log).
  # ----------------------------------------------------------------------------

  defp load_page_sources(page_id, user) do
    case Brain.list_page_sources(page_id, actor: user, load: [:source]) do
      {:ok, page_sources} ->
        page_sources
        |> Enum.map(& &1.source)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  # Sources and history are derived from the page body, so re-read them
  # whenever the body changes in this LiveView, but only after the user has
  # opened the corresponding panel. Otherwise a hidden panel can dominate
  # initial page load and autosave costs.
  defp refresh_page_panels(socket) do
    sources_loaded? = socket.assigns[:page_sources_loaded?] || false
    versions_loaded? = socket.assigns[:page_versions_loaded?] || false

    if sources_loaded? or versions_loaded? do
      page = socket.assigns.page
      user = socket.assigns.current_user

      # Both reads below route through `BrainAccessFilter`; share one access
      # resolution for the pair (scope torn down immediately after).
      {page_sources, page_versions} =
        Magus.Brain.Checks.BrainAccessFilter.with_request_cache(fn ->
          {
            if(sources_loaded?,
              do: load_page_sources(page.id, user),
              else: socket.assigns.page_sources
            ),
            if(versions_loaded?,
              do: load_page_versions(page.id, user),
              else: socket.assigns.page_versions
            )
          }
        end)

      socket
      |> assign(:page_sources, page_sources)
      |> assign(:page_versions, page_versions)
    else
      socket
    end
  end

  defp load_panel(socket, tab) do
    if socket.assigns[:not_found] do
      socket
    else
      Magus.Brain.Checks.BrainAccessFilter.with_request_cache(fn ->
        maybe_load_panel(socket, normalize_panel(tab))
      end)
    end
  end

  defp maybe_load_panel(socket, :outline), do: socket

  defp maybe_load_panel(socket, :sources) do
    if socket.assigns[:page_sources_loaded?] do
      socket
    else
      page = socket.assigns.page
      user = socket.assigns.current_user

      socket
      |> assign(:page_sources, load_page_sources(page.id, user))
      |> assign(:page_sources_loaded?, true)
    end
  end

  defp maybe_load_panel(socket, :related) do
    if socket.assigns[:related_pages_loaded?] do
      socket
    else
      brain = socket.assigns.brain
      page = socket.assigns.page
      user = socket.assigns.current_user

      socket
      |> assign(:related_pages, load_related_pages(brain.id, page.id, user))
      |> assign(:related_pages_loaded?, true)
    end
  end

  defp maybe_load_panel(socket, :activity) do
    if socket.assigns[:page_versions_loaded?] do
      socket
    else
      page = socket.assigns.page
      user = socket.assigns.current_user

      socket
      |> assign(:page_versions, load_page_versions(page.id, user))
      |> assign(:page_versions_loaded?, true)
    end
  end

  defp maybe_load_panel(socket, _), do: socket

  defp normalize_panel(tab) when tab in [:outline, :sources, :related, :activity], do: tab
  defp normalize_panel("outline"), do: :outline
  defp normalize_panel("sources"), do: :sources
  defp normalize_panel("related"), do: :related
  defp normalize_panel("activity"), do: :activity
  defp normalize_panel(_), do: :outline

  # When the page body changes while a version overlay is open, recompute the
  # viewed version's diff so `is_latest?` (and thus the Restore button) stays
  # accurate. A no-op when no overlay is open.
  defp refresh_viewing_version(socket) do
    case socket.assigns[:viewing_version] do
      %{version_id: version_id} ->
        case Brain.page_version_diff(socket.assigns.page.id, version_id) do
          {:ok, data} -> assign(socket, :viewing_version, data)
          :error -> assign(socket, :viewing_version, nil)
        end

      _ ->
        socket
    end
  end

  defp load_related_pages(_brain_id, page_id, user) do
    case Brain.list_backlinks(page_id, load: [:source_page], actor: user) do
      {:ok, links} ->
        links
        |> Enum.map(fn link ->
          page = link.source_page

          %{
            page_id: link.source_page_id,
            brain_id: page && page.brain_id,
            current_title: (page && page.title) || "Untitled",
            link_text: link.target_title_at_link_time,
            drifted?: page != nil and page.title != link.target_title_at_link_time
          }
        end)
        |> Enum.reject(&is_nil(&1.brain_id))

      _ ->
        []
    end
  end

  defp load_page_versions(page_id, _user) do
    Brain.list_page_versions(page_id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      data-brain-page-view
      data-page-id={if @not_found, do: @page_id, else: @page.id}
      class="h-full flex flex-col"
    >
      <div :if={@not_found} class="flex flex-col h-full">
        <%!-- Minimal header so the companion can still be closed (esp.
             on mobile, where the workbench shell hides its own header
             and the companion fills the screen). --%>
        <div
          :if={@role == "companion"}
          class="flex items-center justify-end gap-3 md:px-4 px-14 py-2 border-b border-base-300/50 bg-base-100/80 backdrop-blur-sm"
        >
          <button
            type="button"
            phx-click="close_self_companion"
            class="wb-pill-btn wb-pill-btn-square"
            title="Close"
          >
            <.icon name="lucide-x" class="w-4 h-4" />
          </button>
        </div>
        <div class="flex-1 flex items-center justify-center text-wb-text-muted">
          <p>Brain page not found.</p>
        </div>
      </div>
      <.live_component
        :if={not @not_found}
        module={BrainPaneComponent}
        id={"brain-page-#{@page.id}"}
        brain={@brain}
        page={@page}
        current_user={@current_user}
        brain_pages={@brain_pages}
        brain_pages_json={@brain_pages_json}
        editor_content_json={@editor_content_json}
        page_sources={@page_sources}
        related_pages={@related_pages}
        page_versions={@page_versions}
        viewing_version={@viewing_version}
        brain_page_viewers={Map.get(@viewers || %{}, "presence:page:#{@page.id}", [])}
        role={@role}
        companion_present?={@companion_present?}
      />
      <.live_component
        :if={not @not_found and @brain_file_picker_open?}
        module={MagusWeb.ChatLive.Components.Brain.BrainFilePickerModalComponent}
        id={"brain-file-picker-#{@page.id}"}
        current_user={@current_user}
        brain={@brain}
        page={@page}
      />
    </div>
    """
  end

  @impl true
  def handle_async(:load_brain_pages, {:ok, pages}, socket) do
    pages = pages || []
    serialized = serialize_pages(pages)

    {:noreply,
     socket
     |> assign(:brain_pages, pages)
     |> assign(:brain_pages_json, Jason.encode!(serialized))
     |> Phoenix.LiveView.push_event("brain:update_pages", %{pages: serialized})}
  end

  def handle_async(:load_brain_pages, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "page.updated", payload: %{record: page}},
        socket
      ) do
    if not socket.assigns.not_found and page.id == socket.assigns.page.id do
      {:noreply, assign(socket, :page, page)}
    else
      {:noreply, socket}
    end
  end

  # Workspace sharing was toggled from the brain edit modal or nav.
  # Reload our local brain so the header visibility pill reflects the new
  # state. The broadcast carries the brain.id (not the whole struct) so we
  # refetch with the current actor — keeps authorization in the loop.
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "brain.visibility_changed", payload: payload},
        socket
      ) do
    brain_id = Map.get(payload, :brain_id) || (payload[:brain] && payload[:brain].id)

    if not socket.assigns.not_found and brain_id == socket.assigns.brain.id do
      {:noreply,
       assign(socket, :brain, reload_brain(socket.assigns.brain, socket.assigns.current_user))}
    else
      {:noreply, socket}
    end
  end

  # Page body updates. `BroadcastBrainEvent` emits `page.body_updated`
  # whenever `Page.update_body` runs (editor save in this LV, or the
  # EditBrain agent tool). The payload carries `body`, `lock_version`,
  # `actor_id`, `source`, `modified_at` so the LV can decide between
  # reload and conflict-toast without an extra DB read.
  #
  # Three branches:
  #
  #   1. Self-echo (our own save came back) — `actor_id` matches and the
  #      bumped `lock_version` matches what we just committed. We've
  #      already updated `:page` in `handle_event("brain_editor_save")`,
  #      so this is a no-op.
  #
  #   2. Remote update, no local dirty editor — push `brain:reload_body`
  #      so the hook calls `setContent(prosemirror)` and updates its
  #      `_baseDoc`/`_lockVersion`.
  #
  #   3. Remote update with local dirty editor — push
  #      `brain:conflict_overwrite` so the hook surfaces the LWW
  #      recovery toast (copy-to-clipboard + accept-remote).
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "page.body_updated", payload: payload},
        socket
      ) do
    cond do
      socket.assigns[:not_found] ->
        {:noreply, socket}

      payload[:record] && payload.record.id != socket.assigns.page.id ->
        # Brain-wide broadcast for a sibling page. Ignore.
        {:noreply, socket}

      self_echo?(socket, payload) ->
        {:noreply, socket}

      not (socket.assigns[:has_local_pending_changes?] || false) ->
        page = socket.assigns.page

        updated_page = %{
          page
          | body: payload.body,
            lock_version: payload.lock_version,
            updated_at: payload.modified_at
        }

        {:noreply,
         socket
         |> assign_page(updated_page)
         |> refresh_page_panels()
         |> refresh_viewing_version()
         |> Phoenix.LiveView.push_event("brain:reload_body", %{
           prosemirror: Brain.ProseMirrorProfile.body_to_prosemirror(payload.body),
           lock_version: payload.lock_version,
           modified_at: payload.modified_at
         })}

      true ->
        {:noreply,
         Phoenix.LiveView.push_event(socket, "brain:conflict_overwrite", %{
           current_prosemirror: Brain.ProseMirrorProfile.body_to_prosemirror(payload.body),
           current_version: payload.lock_version,
           conflicting_actor_id: payload[:actor_id],
           your_unsaved_prosemirror:
             Brain.ProseMirrorProfile.body_to_prosemirror(
               socket.assigns[:pending_editor_body] || ""
             )
         })}
    end
  end

  # Companion open/close on this tab. Track local state so the header's
  # "Open chat" button can hide while a companion is already attached.
  def handle_info({:workbench_companion, {:open, _spec}}, socket) do
    {:noreply, assign(socket, :companion_present?, true)}
  end

  def handle_info({:workbench_companion, :close}, socket) do
    {:noreply, assign(socket, :companion_present?, false)}
  end

  # Other tab-chrome broadcasts (active_prompt, insert_text, *_selection)
  # are intended for the chat — ignore here.
  def handle_info({:workbench_chrome, _}, socket), do: {:noreply, socket}

  # Related-tab backlinks and header breadcrumbs both emit `:open_brain_page`.
  # Open the target in a new workbench tab via the user-scoped tabs topic,
  # mirroring the `brain:open_page_ref` ([[wikilink]]) handler.
  def handle_info({BrainPaneComponent, {:open_brain_page, _brain_id, page_id}}, socket) do
    if socket.assigns[:not_found] do
      {:noreply, socket}
    else
      Phoenix.PubSub.broadcast(
        Magus.PubSub,
        "workbench-tabs:#{socket.assigns.current_user.id}",
        {:open_brain_page_in_new_tab, page_id}
      )

      {:noreply, socket}
    end
  end

  def handle_info({BrainPaneComponent, {:load_brain_panel, tab}}, socket) do
    {:noreply, load_panel(socket, tab)}
  end

  def handle_info({BrainPaneComponent, {:update_page_title, title}}, socket) do
    if socket.assigns[:not_found] do
      {:noreply, socket}
    else
      page = socket.assigns.page
      user = socket.assigns.current_user

      case Brain.update_page_title(page, %{title: title}, actor: user) do
        {:ok, updated} ->
          {:noreply, assign(socket, :page, updated)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't rename this page."))}
      end
    end
  end

  def handle_info({BrainPaneComponent, {:view_brain_version, version_id}}, socket) do
    if socket.assigns[:not_found] do
      {:noreply, socket}
    else
      case Brain.page_version_diff(socket.assigns.page.id, version_id) do
        {:ok, data} ->
          {:noreply, assign(socket, :viewing_version, data)}

        :error ->
          {:noreply, put_flash(socket, :error, gettext("That version is no longer available."))}
      end
    end
  end

  def handle_info({BrainPaneComponent, :close_brain_version}, socket) do
    {:noreply, assign(socket, :viewing_version, nil)}
  end

  def handle_info({BrainPaneComponent, {:restore_brain_version, version_id}}, socket) do
    if socket.assigns[:not_found] do
      {:noreply, socket}
    else
      user = socket.assigns.current_user
      page = socket.assigns.page

      with {:ok, body} <- Brain.page_version_body(page.id, version_id),
           {:ok, updated} <-
             Magus.Brain.update_page_body(
               page,
               %{body: body, base_version: page.lock_version},
               actor: user
             ) do
        {:noreply,
         socket
         |> assign_page(updated)
         |> assign(:viewing_version, nil)
         |> refresh_page_panels()
         |> Phoenix.LiveView.push_event("brain:reload_body", %{
           prosemirror: Brain.ProseMirrorProfile.body_to_prosemirror(updated.body),
           lock_version: updated.lock_version,
           modified_at: updated.updated_at
         })}
      else
        :error ->
          {:noreply, put_flash(socket, :error, gettext("That version is no longer available."))}

        {:error, reason} ->
          require Logger

          Logger.warning("brain version restore failed",
            page_id: page.id,
            version_id: version_id,
            reason: inspect(reason)
          )

          {:noreply, put_flash(socket, :error, gettext("Couldn't restore this version."))}
      end
    end
  end

  # User-visible flash from BrainPaneComponent (e.g. drag-drop upload errors).
  def handle_info({BrainPaneComponent, {:flash, kind, message}}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  # Picker modal lifecycle messages from BrainFilePickerModalComponent.
  def handle_info({:close_brain_file_picker, _id}, socket) do
    {:noreply, assign(socket, :brain_file_picker_open?, false)}
  end

  # Picker upload failures: one or more uploaded files could not be saved.
  # Surface a single summarising error flash so the user knows which files
  # failed.
  def handle_info({:brain_file_upload_failed, failures}, socket) when is_list(failures) do
    names =
      failures
      |> Enum.map(fn {name, _reason} -> name end)
      |> Enum.join(", ")

    message = gettext("Could not upload: %{names}", names: names)
    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_info({:brain_files_picked, %{file_ids: file_ids, page_id: page_id}}, socket) do
    require Logger

    user = socket.assigns.current_user
    capped = Enum.take(file_ids, @max_file_picker_inserts)

    socket =
      if length(file_ids) > @max_file_picker_inserts do
        put_flash(
          socket,
          :info,
          gettext("Inserted first %{n} files; the rest were ignored.",
            n: @max_file_picker_inserts
          )
        )
      else
        socket
      end

    # Phase C5: each pick appends a file/image markdown link to the page
    # body. We re-fetch the page on every iteration so each append sees
    # the latest `lock_version` from the previous one — sequential
    # appends to the same page in a tight loop otherwise hit the retry
    # path on every save after the first.
    {failures, _count} =
      Enum.reduce(capped, {[], 0}, fn file_id, {fails, count} ->
        result =
          case Brain.get_page(page_id, actor: user) do
            {:ok, page} ->
              Magus.Brain.BodyAppender.append_file_by_id(page, file_id, "", user)

            {:error, reason} ->
              {:error, reason}
          end

        case result do
          {:ok, _updated_page} ->
            {fails, count + 1}

          {:error, reason} ->
            Logger.warning("brain picker body append failed",
              file_id: file_id,
              page_id: page_id,
              user_id: user && user.id,
              reason: inspect(reason)
            )

            {[file_id | fails], count}
        end
      end)

    socket =
      if failures != [] do
        put_flash(
          socket,
          :error,
          gettext("%{n} file(s) could not be inserted.", n: length(failures))
        )
      else
        socket
      end

    # The `page.body_updated` broadcast fires after each append and
    # triggers `brain:reload_body` in the editor; no manual refresh
    # needed here.
    {:noreply, assign(socket, :brain_file_picker_open?, false)}
  end

  # File-level "update" broadcasts arrive on the user-scoped or workspace-
  # scoped files topic (subscribed in mount/3). When a file referenced by
  # the current page body moves from `:pending`/`:processing` to `:ready`,
  # the file/image NodeView re-renders to the regular card.
  #
  # We only push when the broadcast pertains to a file id present in the
  # page body, and we rebuild the file map from `BodyParser.file_ids/1`
  # so the editor's per-page `__brainFileMaps` entry stays in sync.
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: topic, event: "update", payload: payload},
        socket
      ) do
    if not socket.assigns.not_found and own_file_topic?(topic, socket) do
      file_id = file_id_from_payload(payload)
      body_file_ids = BodyParser.file_ids(socket.assigns.page.body)

      if file_id && file_id in body_file_ids do
        user = socket.assigns.current_user
        file_map = load_body_file_map(body_file_ids, user)

        {:noreply,
         Phoenix.LiveView.push_event(socket, "brain:file-map-updated", %{file_map: file_map})}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Compare against the actual topic this LV subscribed to in `mount/3`,
  # rather than a permissive shape match. Today the LV only subscribes to
  # one workspace's files topic, but pattern-matching `workspaces:*:files`
  # would also accept events for other workspaces if the subscription set
  # ever grows.
  defp own_file_topic?(topic, %{assigns: %{brain: brain, current_user: user}})
       when not is_nil(brain) and not is_nil(user) do
    topic == file_scope_topic(brain, user)
  end

  defp own_file_topic?(_topic, _socket), do: false

  defp file_id_from_payload(%{id: id}) when is_binary(id), do: id
  defp file_id_from_payload(%{file_id: id}) when is_binary(id), do: id
  defp file_id_from_payload(%{data: %{id: id}}) when is_binary(id), do: id
  defp file_id_from_payload(_), do: nil

  # Resolve the file ids referenced by the page body to the JS-shaped
  # `%{file_id => summary}` map consumed by `__brainFileMaps`. Used both
  # on file status broadcasts and (indirectly via the JS hook) when the
  # editor renders attachment NodeViews.
  defp load_body_file_map(file_ids, user) when is_list(file_ids) and file_ids != [] do
    case Magus.Files.get_files_by_ids(file_ids, actor: user) do
      {:ok, files} ->
        Enum.into(files, %{}, fn file ->
          {file.id, Magus.Brain.BlockSerializer.file_summary_for_js(file)}
        end)

      _ ->
        %{}
    end
  end

  defp load_body_file_map(_file_ids, _user), do: %{}

  @impl true
  def handle_event("close_brain_pane", _params, socket) do
    {:noreply, socket}
  end

  # Body-based editor save. The TipTap hook debounces editor updates and
  # pushes `{prosemirror, base_version}` (server-supplied ProseMirror JSON,
  # mirroring the Draft editor). We call
  # `Magus.Brain.update_page_body_from_prosemirror/4` which converts the JSON
  # to markdown, re-attaches frontmatter, and writes through the canonical
  # `update_body` action (optimistic_lock(:lock_version)). On version mismatch
  # the action returns a structured `VersionConflict` carrying the current
  # body and version; we push `brain:conflict_overwrite` to the hook (as
  # ProseMirror JSON) so it can render the LWW recovery toast with a
  # clipboard-copy of the user's unsaved draft.
  def handle_event(
        "brain_editor_save",
        %{"prosemirror" => pm, "base_version" => base_version},
        socket
      )
      when is_map(pm) and is_integer(base_version) do
    if socket.assigns.not_found do
      {:reply, %{ok: false}, socket}
    else
      page = socket.assigns.page
      user = socket.assigns.current_user

      # The save reply MUST carry the authoritative lock_version (success) or
      # an explicit failure flag (conflict / invalid). The BrainTiptapEditor
      # hook syncs `_lockVersion` from `reply.lock_version` and only treats the
      # save as accepted when `reply.ok`. Returning `{:noreply}` here is what
      # caused magus-t12: the client received no reply, optimistically did
      # `_lockVersion += 1` even on a rejected save, and the +1 clobbered the
      # version `brain:conflict_overwrite` had just corrected — a permanent
      # client/server desync where every later autosave conflicted and
      # `setContent` jumped the caret to the document end.
      case Magus.Brain.update_page_body_from_prosemirror(
             page,
             pm,
             base_version,
             actor: user
           ) do
        {:ok, updated} ->
          {:reply, %{ok: true, lock_version: updated.lock_version},
           socket
           |> assign_page(updated)
           |> assign(:has_local_pending_changes?, false)
           |> assign(:pending_editor_body, nil)
           |> refresh_page_panels()}

        {:error, %Ash.Error.Invalid{errors: errors}} ->
          case Enum.find(errors, &match?(%VersionConflict{}, &1)) do
            %VersionConflict{} = conflict ->
              {:reply, %{ok: false},
               Phoenix.LiveView.push_event(socket, "brain:conflict_overwrite", %{
                 current_prosemirror:
                   Brain.ProseMirrorProfile.body_to_prosemirror(conflict.current_body),
                 current_version: conflict.current_version,
                 conflicting_actor_id: conflict.conflicting_actor_id,
                 your_unsaved_prosemirror: pm
               })}

            _ ->
              {:reply, %{ok: false},
               socket
               |> put_flash(:error, "Could not save: invalid input")
               |> Phoenix.LiveView.push_event("brain:reload_body", %{
                 prosemirror: Brain.ProseMirrorProfile.body_to_prosemirror(page.body || ""),
                 lock_version: page.lock_version,
                 modified_at: page.updated_at
               })}
          end

        {:error, _other} ->
          {:reply, %{ok: false},
           socket
           |> put_flash(:error, "Save failed, please try again")
           |> Phoenix.LiveView.push_event("brain:reload_body", %{
             prosemirror: Brain.ProseMirrorProfile.body_to_prosemirror(page.body || ""),
             lock_version: page.lock_version,
             modified_at: page.updated_at
           })}
      end
    end
  end

  # Hook tells us the editor became dirty (first keystroke after a save).
  # We track this so `handle_info({:page_body_updated, ...})` can decide
  # between `brain:reload_body` (clean editor) and `brain:conflict_overwrite`
  # (dirty editor) on remote updates.
  def handle_event("brain_editor_dirty", _params, socket) do
    {:noreply, assign(socket, :has_local_pending_changes?, true)}
  end

  def handle_event("brain_editor_clean", _params, socket) do
    {:noreply,
     socket
     |> assign(:has_local_pending_changes?, false)
     |> assign(:pending_editor_body, nil)}
  end

  # Per-page presence: hook reports viewing vs editing state. We track the
  # current user on the `brain:page:<page_id>` topic via Phoenix.Presence
  # so the JS hook can render the "X is editing, take over" overlay.
  def handle_event("brain_editor_presence", %{"state" => state}, socket)
      when state in ["viewing", "editing"] do
    if socket.assigns.not_found do
      {:noreply, socket}
    else
      user = socket.assigns.current_user
      page = socket.assigns.page
      topic = "brain:page:#{page.id}"

      meta = %{
        state: state,
        user_id: user.id,
        last_activity_at: System.system_time(:second)
      }

      # Update existing presence entry; silently noop if the user isn't tracked
      # on this topic yet (mount hasn't run the initial Tracker.track call).
      _ = Magus.Presence.Tracker.update(self(), topic, user.id, fn _ -> meta end)

      {:noreply, socket}
    end
  end

  # Click on a file block dispatches `phx:open-brain-file` from the JS
  # NodeView; the BrainTiptapEditor hook forwards it here as `open_brain_file`.
  # Routing depends on `tab_role`:
  #
  #   - "primary"   → open the file as a companion of this tab. The brain
  #                   pane is the primary content; the file slides in next
  #                   to it.
  #   - "companion" → the brain itself is already a companion. Avoid
  #                   triple-nesting by opening the file in a new workbench
  #                   tab instead. We ask `WorkbenchLive` (a separate LV
  #                   process) over the user-scoped tabs PubSub topic.
  def handle_event("open_brain_file", %{"file_id" => file_id} = params, socket) do
    tab_role = params["tab_role"] || socket.assigns.role
    user = socket.assigns.current_user
    tab_id = socket.assigns.tab_id

    case Magus.Files.get_file(file_id, actor: user) do
      {:ok, file} ->
        socket = handle_open_brain_file(socket, file, tab_role, tab_id, user)
        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, "File no longer available")}
    end
  end

  # Drop a file row from the workbench Files sidebar onto the editor.
  # The TipTap drop handler dispatches `phx:link-brain-file` on the window;
  # the BrainTiptapEditor hook re-pushes it here as `link_brain_file` after
  # filtering by page id. Block creation goes through the same funnel as
  # the picker / slash / OS-file paths so workspace-scope validation runs
  # in `FileInSameWorkspace`. On error we surface a flash; on success the
  # `block.created` PubSub fan-out refreshes the editor.
  def handle_event("link_brain_file", %{"file_id" => file_id}, socket) do
    if socket.assigns.not_found do
      {:noreply, socket}
    else
      user = socket.assigns.current_user
      page = socket.assigns.page

      # Phase C5: append the markdown link to the page body rather than
      # creating a typed `:file` block. Workspace cross-check is enforced
      # by `Magus.Brain.Page.Validations.FileReferencesInWorkspace`
      # inside `update_page_body`, so the workspace-mismatch detection
      # below still kicks in.
      case Magus.Brain.BodyAppender.append_file_by_id(page, file_id, "", user) do
        {:ok, _updated_page} ->
          {:noreply, socket}

        {:error, reason} ->
          require Logger

          if workspace_mismatch_error?(reason) do
            Logger.debug("sidebar drag rejected: workspace mismatch",
              file_id: file_id,
              page_id: page.id,
              user_id: user && user.id
            )

            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("That file is in a different workspace and can't be added here.")
             )}
          else
            Logger.warning("sidebar drag failed",
              reason: inspect(reason),
              file_id: file_id,
              page_id: page.id,
              user_id: user && user.id
            )

            {:noreply,
             put_flash(socket, :error, gettext("Could not link file to this brain page."))}
          end
      end
    end
  end

  # Slash `/file` opens the picker. New blocks are appended at the end
  # of the page by `AutoPosition`; positional insert at the slash command
  # cursor would require a position-aware funnel and is deferred.
  def handle_event("open_brain_file_picker", params, socket) do
    page = socket.assigns[:page]

    if page && to_string(page.id) == to_string(params["page_id"] || page.id) do
      {:noreply, assign(socket, :brain_file_picker_open?, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_self_companion", _params, socket) do
    if tab_id = socket.assigns[:tab_id] do
      MagusWeb.Workbench.Signals.broadcast_close_companion(tab_id)
    end

    {:noreply, socket}
  end

  def handle_event("open_companion_chat", _params, socket) do
    user = socket.assigns.current_user
    page = socket.assigns[:page]
    tab_id = socket.assigns[:tab_id]

    if page && tab_id do
      case Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user) do
        {:ok, conv} ->
          MagusWeb.Workbench.Signals.broadcast_open_companion(tab_id, %{
            "type" => "conversation",
            "id" => conv.id
          })

          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Couldn't open chat for this page.")}
      end
    else
      {:noreply, socket}
    end
  end

  # The TipTap page-link extension dispatches `brain:open_page_ref` with
  # the link's title when the user clicks `[[Some Page]]`. Resolve it
  # against the in-memory sibling list and ask WorkbenchLive to open it. The
  # sibling list loads asynchronously after mount, so fall back to a direct
  # title lookup if the user clicks a page ref before that async task returns.
  def handle_event("brain:open_page_ref", %{"title" => title}, socket)
      when is_binary(title) do
    pages = socket.assigns[:brain_pages] || []
    user = socket.assigns.current_user

    case Enum.find(pages, &(&1.title == title)) do
      %{id: page_id} ->
        broadcast_open_brain_page(user, page_id)
        {:noreply, socket}

      nil ->
        case Brain.find_page_by_title(socket.assigns.brain.id, title, actor: user) do
          {:ok, [%{id: page_id} | _]} ->
            broadcast_open_brain_page(user, page_id)
            {:noreply, socket}

          _ ->
            {:noreply,
             put_flash(socket, :info, gettext("No page named \"%{title}\".", title: title))}
        end
    end
  end

  def handle_event("brain:open_page_ref", _params, socket), do: {:noreply, socket}

  # The brain editor's "Source" slash command dispatches `brain:add_source`
  # with a URL. We append a fenced ` ```source ` block to the page body
  # via `BodyAppender.append_source/3`; the `page.body_updated` broadcast
  # then drives the editor refresh.
  def handle_event("brain:add_source", %{"url" => url}, socket) when is_binary(url) do
    case socket.assigns[:page] do
      nil ->
        {:noreply, socket}

      page ->
        user = socket.assigns.current_user

        case Magus.Brain.BodyAppender.append_source(
               page,
               %{url: url, source_type: "web"},
               user
             ) do
          {:ok, _updated_page} ->
            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't add source."))}
        end
    end
  end

  def handle_event("brain:add_source", _params, socket), do: {:noreply, socket}

  # Bubble-menu Ask. Two flows:
  #
  #   1. Brain is a *companion* of a chat tab: a sibling primary
  #      `ConversationView` already subscribes to the tab topic; broadcast
  #      the selection and it shows up in the chat input as a chip.
  #
  #   2. Brain is the *primary* and there's no chat yet: open one via
  #      `find_or_create_companion_conversation/3` and embed the selection
  #      in the open-companion spec so `TabContainer` threads it through
  #      into the freshly-mounted `ConversationView`'s session. Also
  #      broadcast on the tab topic to handle the "companion already open"
  #      case (the existing chat picks it up live).
  def handle_event("brain:ask_about_selection", %{"text" => text} = _params, socket)
      when is_binary(text) and byte_size(text) > 0 do
    user = socket.assigns.current_user
    page = socket.assigns[:page]
    tab_id = socket.assigns[:tab_id]
    role = socket.assigns[:role]

    payload = %{
      "text" => text,
      "page_title" => (page && page.title) || ""
    }

    cond do
      is_nil(page) or is_nil(tab_id) ->
        {:noreply, socket}

      role == "primary" ->
        case Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user) do
          {:ok, conv} ->
            MagusWeb.Workbench.Signals.broadcast_open_companion(tab_id, %{
              "type" => "conversation",
              "id" => conv.id,
              "initial_brain_selection" => payload
            })

            MagusWeb.Workbench.Signals.broadcast_brain_selection(tab_id, payload)
            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't open chat for this page."))}
        end

      true ->
        # Companion role: a primary chat already exists on this tab.
        MagusWeb.Workbench.Signals.broadcast_brain_selection(tab_id, payload)
        {:noreply, socket}
    end
  end

  def handle_event("brain:ask_about_selection", _params, socket), do: {:noreply, socket}

  defp handle_open_brain_file(socket, file, "companion", _tab_id, _user) do
    # Brain pane is itself a companion. Ask WorkbenchLive (a separate LV
    # process subscribed to `workbench-tabs:<user_id>`) to open the file
    # in a new workbench tab. Avoids triple-nesting.
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      "workbench-tabs:#{socket.assigns.current_user.id}",
      {:open_file_in_new_tab, file.id}
    )

    socket
  end

  defp handle_open_brain_file(socket, _file, _role, nil, _user), do: socket

  defp handle_open_brain_file(socket, file, _primary, tab_id, _user) do
    # Default (and "primary"): open the file as a companion of this tab.
    # We pick the companion type that maps to a TabContainer renderer:
    # PDFs use the PdfCompanion, spreadsheets use SpreadsheetCompanion,
    # everything else falls back to opening in a new workbench tab since
    # there is no generic file companion renderer yet.
    case file_companion_spec(file) do
      {:ok, spec} ->
        MagusWeb.Workbench.Signals.broadcast_open_companion(tab_id, spec)
        socket

      :unsupported ->
        Phoenix.PubSub.broadcast(
          Magus.PubSub,
          "workbench-tabs:#{socket.assigns.current_user.id}",
          {:open_file_in_new_tab, file.id}
        )

        socket
    end
  end

  defp file_companion_spec(%{mime_type: "application/pdf"} = file) do
    case file.file_path && Magus.Files.Storage.get_url(file.file_path) do
      {:ok, url} ->
        {:ok,
         %{
           "type" => "pdf",
           "id" => file.id,
           "name" => file.name || file.id,
           "url" => url
         }}

      _ ->
        :unsupported
    end
  end

  defp file_companion_spec(%{mime_type: mime} = file)
       when mime in [
              "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
              "application/vnd.ms-excel",
              "text/csv"
            ] do
    {:ok,
     %{
       "type" => "spreadsheet",
       "id" => file.id,
       "name" => file.name || file.id
     }}
  end

  defp file_companion_spec(_), do: :unsupported

  # Detect a workspace-scope validation failure from the file block create.
  # `Magus.Brain.Block.Validations.FileInSameWorkspace` tags the failure with
  # `vars: [reason: :workspace_mismatch]` on its `InvalidAttribute` exception.
  # Match on that structured tag rather than the message text so future
  # message tweaks don't silently break the UX path. A substring fallback
  # remains as a safety net in case the tag is ever dropped.
  defp workspace_mismatch_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &workspace_mismatch_error?/1)
  end

  defp workspace_mismatch_error?(%{vars: vars}) when is_list(vars) do
    Keyword.get(vars, :reason) == :workspace_mismatch
  end

  defp workspace_mismatch_error?(%{vars: vars}) when is_map(vars) do
    Map.get(vars, :reason) == :workspace_mismatch
  end

  defp workspace_mismatch_error?(%{message: message}) when is_binary(message) do
    message =~ "workspace does not match"
  end

  defp workspace_mismatch_error?(_), do: false

  defp broadcast_open_brain_page(user, page_id) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      "workbench-tabs:#{user.id}",
      {:open_brain_page_in_new_tab, page_id}
    )
  end

  # Phase C1: self-echo detection for the `page.body_updated` PubSub
  # handler. When the broadcast carries our own actor_id AND the
  # advertised lock_version matches the page we already have locally,
  # treat it as our own save coming back so we don't double-apply.
  # The full conflict-detection wiring (assigning :pending_editor_body
  # / :has_local_pending_changes? on the save path) lands with the rest
  # of C1; this helper is the minimal piece needed for the
  # `page.body_updated` handler to compile.
  defp self_echo?(socket, payload) do
    user = socket.assigns[:current_user]
    page = socket.assigns[:page]
    actor_id = payload[:actor_id]
    lock_version = payload[:lock_version]

    cond do
      is_nil(user) or is_nil(page) -> false
      actor_id == nil -> false
      actor_id != user.id -> false
      is_nil(lock_version) -> true
      lock_version == page.lock_version -> true
      true -> false
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if not Map.get(socket.assigns, :not_found, true) do
      brain = socket.assigns[:brain]
      page = socket.assigns[:page]
      user = socket.assigns[:current_user]

      if brain && page do
        Magus.Endpoint.unsubscribe(Brain.Topics.brain(brain.id))
        Magus.Endpoint.unsubscribe(Brain.Topics.page(brain.id, page.id))

        # Symmetric with mount/3 which also subscribes to the file scope
        # topic. Without this the LV process leaks a Phoenix.PubSub
        # subscription on every disconnect.
        if user do
          Magus.Endpoint.unsubscribe(file_scope_topic(brain, user))
        end
      end
    end

    :ok
  end
end
