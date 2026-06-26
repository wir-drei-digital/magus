defmodule MagusWeb.Workbench.Modes.FilesModeNav do
  @moduledoc """
  Files mode sidebar: entry points · filter pills · storage meter.

  All filter changes go through the URL: clicking a pill broadcasts a
  `:file_browser_patch_from_sidebar` message on the workbench user topic;
  WorkbenchLive computes the new URL and `push_patch`es. The actual
  filtering happens in the file browser LV after the URL params change.
  """
  use MagusWeb, :live_component

  alias Magus.Usage.Calculator
  alias MagusWeb.Workbench.Modes.FilesModeNav.Data

  @pill_keys ~w(type modified source)

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:expanded_collection_ids, MapSet.new())
     |> assign(:open_pill, nil)
     |> assign(:storage, %{used: 0, limit: nil, percent: 0, exempt: false})
     |> assign(:storage_loaded?, false)}
  end

  @impl true
  def update(%{storage: storage}, socket) when is_map(storage) do
    {:ok,
     socket
     |> assign(:storage, storage)
     |> assign(:storage_loaded?, true)}
  end

  def update(assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:reload]))

    user = socket.assigns[:current_user]
    workspace_id = socket.assigns[:workspace_id]

    %{entry_points: entry_points, collections: collections} =
      Data.load(%{
        user: user,
        workspace_id: workspace_id,
        expanded_collection_ids: socket.assigns.expanded_collection_ids
      })

    socket =
      socket
      |> assign(:entry_points, entry_points)
      |> assign(:collections, collections)
      |> assign(:active_filters, active_tab_filters(socket.assigns))

    {:ok, maybe_load_storage_async(socket, user)}
  end

  defp maybe_load_storage_async(socket, nil), do: socket

  defp maybe_load_storage_async(socket, user) do
    if socket.assigns.storage_loaded? do
      socket
    else
      myself = socket.assigns.myself

      Task.start(fn ->
        Phoenix.LiveView.send_update(myself, storage: compute_storage(user))
      end)

      socket
    end
  end

  @impl true
  def handle_event("toggle_collection_group", _params, socket) do
    expanded =
      if MapSet.size(socket.assigns.expanded_collection_ids) > 0 do
        MapSet.new()
      else
        MapSet.new([:knowledge])
      end

    %{collections: collections} =
      Data.load(%{
        user: socket.assigns.current_user,
        workspace_id: socket.assigns[:workspace_id],
        expanded_collection_ids: expanded
      })

    {:noreply,
     socket
     |> assign(:expanded_collection_ids, expanded)
     |> assign(:collections, collections)}
  end

  def handle_event("open_pill", %{"key" => key}, socket) when key in @pill_keys do
    open = socket.assigns.open_pill
    new_open = if to_string(open) == key, do: nil, else: String.to_existing_atom(key)
    {:noreply, assign(socket, :open_pill, new_open)}
  end

  def handle_event("open_pill", _params, socket), do: {:noreply, socket}

  def handle_event("set_pill_value", %{"key" => key, "value" => value}, socket)
      when key in @pill_keys do
    user_id = socket.assigns.current_user.id
    overrides = %{key => normalize_pill_value(value)}

    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      MagusWeb.Workbench.Signals.workbench_user_topic(user_id),
      {:file_browser_patch_from_sidebar, overrides}
    )

    {:noreply, assign(socket, :open_pill, nil)}
  end

  def handle_event("set_pill_value", _params, socket), do: {:noreply, socket}

  defp normalize_pill_value("any"), do: nil
  defp normalize_pill_value(""), do: nil
  defp normalize_pill_value(v), do: v

  defp active_tab_filters(%{active_browser_filters: f}) when is_map(f), do: f
  defp active_tab_filters(_), do: %{}

  defp compute_storage(user) do
    case Calculator.get_effective_limits(user.id) do
      %{exempt: true} ->
        %{used: 0, limit: nil, percent: 0, exempt: true}

      limits ->
        used = Calculator.get_storage_used(user.id)
        limit = limits[:storage_bytes]

        percent =
          cond do
            is_nil(limit) -> 0
            limit == 0 -> 100
            true -> min(100, used / limit * 100) |> Float.round(1)
          end

        %{used: used, limit: limit, percent: percent, exempt: false}
    end
  rescue
    _ -> %{used: 0, limit: nil, percent: 0, exempt: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="files-mode-nav h-full flex flex-col text-sm">
      <div class="flex-1 min-h-0 overflow-auto p-2 space-y-1">
        <%= for ep <- @entry_points do %>
          <%= if ep[:expandable?] do %>
            <button
              type="button"
              phx-click="toggle_collection_group"
              phx-target={@myself}
              class="w-full flex items-center gap-2 px-2 py-1.5 rounded-md text-wb-text-secondary hover:bg-wb-hover hover:text-wb-text transition-colors"
            >
              <.icon name={ep.icon} class="w-4 h-4" />
              <span class="flex-1 text-left">{ep.label}</span>
              <.icon
                name={
                  if MapSet.size(@expanded_collection_ids) > 0,
                    do: "lucide-chevron-down",
                    else: "lucide-chevron-right"
                }
                class="w-3 h-3 text-wb-text-dim"
              />
            </button>

            <div :if={MapSet.size(@expanded_collection_ids) > 0} class="pl-6 space-y-1">
              <.link
                :for={c <- @collections}
                patch={c.path}
                class="flex items-center gap-2 px-2 py-1 rounded-md text-xs text-wb-text-secondary hover:bg-wb-hover hover:text-wb-text transition-colors"
              >
                <.icon name={c.icon} class="w-3.5 h-3.5" />
                {c.label}
              </.link>
              <div :if={@collections == []} class="text-xs text-wb-text-dim px-2 py-1">
                {gettext("No collections")}
              </div>
            </div>
          <% else %>
            <.link
              patch={ep.path}
              class="flex items-center gap-2 px-2 py-1.5 rounded-md text-wb-text-secondary hover:bg-wb-hover hover:text-wb-text transition-colors"
            >
              <.icon name={ep.icon} class="w-4 h-4" />
              <span>{ep.label}</span>
            </.link>
          <% end %>
        <% end %>

        <%!-- Filters are hidden for now. Flipping `:if={false}` to a real condition
             re-enables them; kept compiled so the helpers stay used. --%>
        <div :if={false} class="pt-3">
          <div class="px-2 text-[10px] uppercase tracking-wider text-wb-text-dim mb-1">
            {gettext("Filters")}
          </div>
          <div class="flex flex-wrap gap-1 px-2">
            <.pill
              myself={@myself}
              key="type"
              label={pill_label(gettext("Type"), @active_filters["type"])}
              open?={@open_pill == :type}
            >
              <.pill_choice myself={@myself} key="type" value="any" label={gettext("Any")} />
              <.pill_choice myself={@myself} key="type" value="image" label={gettext("Image")} />
              <.pill_choice myself={@myself} key="type" value="video" label={gettext("Video")} />
              <.pill_choice myself={@myself} key="type" value="pdf" label={gettext("PDF")} />
              <.pill_choice myself={@myself} key="type" value="document" label={gettext("Document")} />
              <.pill_choice myself={@myself} key="type" value="text" label={gettext("Text")} />
              <.pill_choice myself={@myself} key="type" value="email" label={gettext("Email")} />
            </.pill>

            <.pill
              myself={@myself}
              key="modified"
              label={pill_label(gettext("Modified"), @active_filters["modified"])}
              open?={@open_pill == :modified}
            >
              <.pill_choice myself={@myself} key="modified" value="any" label={gettext("Any time")} />
              <.pill_choice myself={@myself} key="modified" value="today" label={gettext("Today")} />
              <.pill_choice
                myself={@myself}
                key="modified"
                value="this_week"
                label={gettext("This week")}
              />
              <.pill_choice
                myself={@myself}
                key="modified"
                value="this_month"
                label={gettext("This month")}
              />
              <.pill_choice
                myself={@myself}
                key="modified"
                value="this_year"
                label={gettext("This year")}
              />
              <.pill_choice myself={@myself} key="modified" value="older" label={gettext("Older")} />
            </.pill>

            <.pill
              myself={@myself}
              key="source"
              label={pill_label(gettext("Source"), @active_filters["source"])}
              open?={@open_pill == :source}
            >
              <.pill_choice myself={@myself} key="source" value="any" label={gettext("Any")} />
              <.pill_choice myself={@myself} key="source" value="uploaded" label={gettext("Upload")} />
              <.pill_choice myself={@myself} key="source" value="agent" label={gettext("Generated")} />
              <.pill_choice myself={@myself} key="source" value="synced" label={gettext("Synced")} />
            </.pill>
          </div>
        </div>
      </div>

      <div class="border-t border-wb-border p-3 text-xs">
        <div class="text-wb-text-dim mb-1">{gettext("Storage")}</div>
        <div class="h-1.5 bg-wb-surface rounded-full overflow-hidden">
          <div class="h-full bg-wb-accent" style={"width: #{@storage.percent}%"}></div>
        </div>
        <div class="mt-1">
          <%= if @storage.exempt do %>
            {gettext("Unlimited")}
          <% else %>
            {format_bytes(@storage.used)} {gettext("of")} {format_bytes(@storage.limit)}
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :myself, :any, required: true
  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :open?, :boolean, default: false
  slot :inner_block, required: true

  defp pill(assigns) do
    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click="open_pill"
        phx-value-key={@key}
        phx-target={@myself}
        class="text-[11px] px-2 py-0.5 border border-wb-border rounded-full hover:bg-wb-hover"
      >
        {@label}
      </button>
      <div
        :if={@open?}
        class="absolute left-0 mt-1 z-10 bg-wb-bg border border-wb-border rounded-md py-1 min-w-[140px] shadow-lg"
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :myself, :any, required: true
  attr :key, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true

  defp pill_choice(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_pill_value"
      phx-value-key={@key}
      phx-value-value={@value}
      phx-target={@myself}
      class="w-full text-left px-3 py-1 hover:bg-wb-hover text-xs"
    >
      {@label}
    </button>
    """
  end

  defp pill_label(name, nil), do: name
  defp pill_label(name, ""), do: name
  defp pill_label(name, "any"), do: name
  defp pill_label(name, value), do: "#{name}: #{String.capitalize(value)}"

  defp format_bytes(nil), do: "-"
  defp format_bytes(b) when b < 1024, do: "#{b} B"
  defp format_bytes(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"

  defp format_bytes(b) when b < 1024 * 1024 * 1024,
    do: "#{Float.round(b / (1024 * 1024), 1)} MB"

  defp format_bytes(b), do: "#{Float.round(b / (1024 * 1024 * 1024), 2)} GB"
end
