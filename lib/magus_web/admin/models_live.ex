defmodule MagusWeb.Admin.ModelsLive do
  @moduledoc """
  Admin view for managing AI models.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Formatters
  alias MagusWeb.Layouts
  alias MagusWeb.Admin.ModelsLive.Listing
  alias Magus.Chat.Model
  alias Magus.Chat.RoutingSlot
  alias Magus.Models.ModelReferences

  @specialties [:general, :coding, :search, :reasoning, :creative]
  @tiers [:simple, :standard, :complex]
  @media_specialties [:image, :text_to_video, :image_to_video]

  # Cap rendered registry rows so a provider with hundreds of models (e.g.
  # openrouter has 300+) doesn't render one giant table; users refine via the
  # filter input. Server-side filter logic is unchanged.
  @registry_render_cap 100

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Models")
      |> assign(:current_path, "/admin/models")
      |> assign(:show_routing_modal, false)
      |> assign(:routing_grid, %{})
      |> assign(:original_routing_grid, %{})
      |> assign(:active_models, [])
      |> assign(:specialties, @specialties)
      |> assign(:tiers, @tiers)
      |> assign(:image_models, [])
      |> assign(:video_models, [])
      |> assign(:image_to_video_models, [])
      |> assign(:providers, Magus.Models.list_providers!(authorize?: false))
      # Delete-confirm flow: %{model: model, counts: %{...}} or nil
      |> assign(:delete_target, nil)
      # Registry picker state
      |> assign(:registry_provider, nil)
      |> assign(:registry_models, [])
      |> assign(:registry_filter, "")
      |> assign(:registry_vendor, "")
      |> assign(:registry_sort, :id_asc)
      # Main-list filter/sort/page state (mirrors the URL query string)
      |> assign(:list_params, %{})
      |> load_models()

    {:ok, socket}
  end

  # Loads the full catalog once with usage aggregates (single query, no longer a
  # per-model MessageUsage scan). The list is small and admin-curated, so the
  # visible page is derived in-memory by Listing from `@list_params`.
  defp load_models(socket) do
    require Ash.Query

    all_models =
      Model
      |> Ash.Query.for_read(:read)
      |> Ash.Query.load([:model_provider, :usage_count, :usage_input_cost, :usage_output_cost])
      |> Ash.read!(authorize?: false)

    socket
    |> assign(:all_models, all_models)
    |> recompute_listing()
  end

  # Re-derives the visible page from the loaded catalog + current filter/sort/
  # page params. Called after every reload (toggle/delete/save-routing) so the
  # admin stays on the same filtered view.
  defp recompute_listing(socket) do
    assign(socket, :listing, Listing.apply(socket.assigns.all_models, socket.assigns.list_params))
  end

  @list_param_keys ~w(status provider caps sort dir page)

  defp take_list_params(params), do: Map.take(params, @list_param_keys)

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    socket
    |> assign(:page_title, "Models")
    |> assign(:model, nil)
    |> assign(:form, nil)
    |> assign(:list_params, take_list_params(params))
    |> recompute_listing()
  end

  defp apply_action(socket, :new, _params) do
    model = %Model{}
    # When arriving from the registry picker the prefill params were stashed
    # in assigns; consume them so a plain "New Model" visit stays blank.
    prefill = socket.assigns[:registry_prefill] || %{}
    form = create_form(prefill)

    socket
    |> assign(:page_title, "New Model")
    |> assign(:model, model)
    |> assign(:form, form)
    |> assign(:desc_tab, "en")
    |> assign(:openrouter_provider_slugs, load_openrouter_provider_slugs(socket))
    |> assign(:registry_prefill, nil)
  end

  defp apply_action(socket, :from_registry, _params) do
    socket
    |> assign(:page_title, "Add from Registry")
    |> assign(:model, nil)
    |> assign(:form, nil)
    |> assign(:registry_provider, nil)
    |> assign(:registry_models, [])
    |> assign(:registry_filter, "")
    |> assign(:registry_vendor, "")
    |> assign(:registry_sort, :id_asc)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Ash.get(Model, id, authorize?: false) do
      {:ok, model} ->
        form = update_form(model)

        socket
        |> assign(:page_title, "Edit #{model.name}")
        |> assign(:model, model)
        |> assign(:form, form)
        |> assign(:desc_tab, "en")
        |> assign(:openrouter_provider_slugs, load_openrouter_provider_slugs(socket))

      {:error, _} ->
        socket
        |> put_flash(:error, "Model not found")
        |> push_navigate(to: ~p"/admin/models")
    end
  end

  defp provider_options(providers) do
    [{"-- none --", ""}] ++ Enum.map(providers, fn p -> {p.name, p.id} end)
  end

  # Synced OpenRouter provider slugs, offered as the denied_providers checkbox
  # options in the model form. Admin-gated read; the current user is the actor.
  defp load_openrouter_provider_slugs(socket) do
    Magus.Models.list_open_router_providers!(actor: socket.assigns.current_user)
    |> Enum.map(& &1.slug)
    |> Enum.sort()
  end

  defp create_form(prefill) do
    form =
      Model
      |> AshPhoenix.Form.for_create(:create,
        authorize?: false,
        forms: [auto?: true]
      )

    form =
      if prefill == %{} do
        form
      else
        AshPhoenix.Form.validate(form, prefill)
      end

    to_form(form)
  end

  defp update_form(model) do
    model
    |> AshPhoenix.Form.for_update(:update,
      authorize?: false,
      forms: [auto?: true]
    )
    |> to_form()
  end

  # ============================================================================
  # Routing Modal Events
  # ============================================================================

  @impl true
  def handle_event("open_routing_modal", _params, socket) do
    active_models = list_active_models()
    grid = build_routing_grid()
    image_models = list_models_by_output_modality("image")
    video_models = list_models_by_output_modality("video")
    image_to_video_models = list_image_to_video_models()

    socket =
      socket
      |> assign(:show_routing_modal, true)
      |> assign(:active_models, active_models)
      |> assign(:routing_grid, grid)
      |> assign(:original_routing_grid, grid)
      |> assign(:image_models, image_models)
      |> assign(:video_models, video_models)
      |> assign(:image_to_video_models, image_to_video_models)

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_routing_modal", _params, socket) do
    {:noreply, assign(socket, :show_routing_modal, false)}
  end

  @impl true
  def handle_event("routing_slot_change", params, socket) do
    with {:ok, specialty} <-
           validate_routing_enum(params["specialty"], @specialties ++ @media_specialties),
         {:ok, tier} <- validate_routing_enum(params["tier"], @tiers) do
      model_id = if params["model_id"] == "", do: nil, else: params["model_id"]

      grid = Map.put(socket.assigns.routing_grid, {specialty, tier}, model_id)

      {:noreply, assign(socket, :routing_grid, grid)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_routing", _params, socket) do
    grid = socket.assigns.routing_grid
    original = socket.assigns.original_routing_grid

    # Find all slots that changed
    chat_slots = for s <- @specialties, t <- @tiers, do: {s, t}
    media_slots = for s <- @media_specialties, do: {s, :standard}
    all_slots = chat_slots ++ media_slots

    changed_slots =
      Enum.filter(all_slots, fn slot -> grid[slot] != original[slot] end)

    errors =
      Enum.reduce(changed_slots, [], fn {specialty, tier} = _slot, errs ->
        model_id = grid[{specialty, tier}]

        result =
          if model_id do
            # Upsert: assign model to this slot
            Magus.Chat.upsert_routing_slot(model_id, specialty, tier, authorize?: false)
          else
            # Remove: delete the slot if it existed
            delete_routing_slot(specialty, tier)
          end

        case result do
          {:ok, _} -> errs
          :ok -> errs
          {:error, _} -> ["#{specialty}/#{tier}" | errs]
        end
      end)

    socket =
      if errors == [] do
        socket
        |> put_flash(:info, "Routing configuration saved")
        |> assign(:show_routing_modal, false)
        |> load_models()
      else
        put_flash(socket, :error, "Failed to update: #{Enum.join(errors, ", ")}")
      end

    {:noreply, socket}
  end

  # ============================================================================
  # Form Events
  # ============================================================================

  @impl true
  def handle_event("switch_desc_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :desc_tab, tab)}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form.source, params)
    {:noreply, assign(socket, :form, to_form(form))}
  end

  @impl true
  def handle_event("save", %{"form" => params}, socket) do
    if admin?(socket) do
      case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
        {:ok, _model} ->
          action = if socket.assigns.live_action == :new, do: "created", else: "updated"

          {:noreply,
           socket
           |> put_flash(:info, "Model #{action} successfully")
           |> push_navigate(to: ~p"/admin/models")}

        {:error, form} ->
          {:noreply, assign(socket, :form, to_form(form))}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    if admin?(socket) do
      case Ash.get(Model, id, authorize?: false) do
        {:ok, model} ->
          result =
            model
            |> Ash.Changeset.for_update(:update, %{active?: !model.active?})
            |> Ash.update(authorize?: false)

          case result do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Model #{if model.active?, do: "disabled", else: "enabled"}")
               |> load_models()}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to update model")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Model not found")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    # Non-Ash read for lifecycle guidance: explicitly guard admin.
    if admin?(socket) do
      case Ash.get(Model, id, authorize?: false) do
        {:ok, model} ->
          counts = ModelReferences.counts(model.id)

          {:noreply, assign(socket, :delete_target, %{model: model, counts: counts})}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Model not found")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_target, nil)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    if admin?(socket) do
      case Ash.get(Model, id, authorize?: false) do
        {:ok, model} ->
          case Ash.destroy(model, authorize?: false) do
            :ok ->
              {:noreply,
               socket
               |> assign(:delete_target, nil)
               |> put_flash(:info, "Model deleted successfully")
               |> load_models()}

            {:error, _} ->
              # FK-restricted (Postgres restricts; surfaces as Ash.Error.Invalid
              # "would leave records behind"). Catch generically: tables beyond
              # the three counted (users.selected_model_id, etc.) can also block,
              # so the guidance must work even when counts are all zero.
              counts = ModelReferences.counts(model.id)

              {:noreply,
               socket
               |> assign(:delete_target, nil)
               |> put_flash(:error, delete_blocked_message(counts))}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Model not found")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  # ============================================================================
  # Index Filter / Sort / Page
  # ============================================================================

  # Pure view-state navigation: translates the filter form into the URL. The
  # actual data view is recomputed in handle_params -> apply_action(:index),
  # which is admin-gated by the live_session, so no extra guard is needed here.
  @impl true
  def handle_event("apply_filters", params, socket) do
    caps = params |> Map.get("caps", []) |> List.wrap() |> Enum.join(",")

    list_params =
      socket.assigns.list_params
      |> Map.put("status", params["status"] || "all")
      |> Map.put("provider", params["provider"] || "")
      |> Map.put("caps", caps)
      # Any filter change returns to the first page.
      |> Map.delete("page")

    {:noreply, push_patch(socket, to: list_path(list_params))}
  end

  # Registry picker
  @impl true
  def handle_event("select_registry_provider", params, socket) do
    # Non-Ash registry browsing: explicitly guard admin.
    if admin?(socket) do
      provider_id = params["provider_id"] || params["value"]

      provider =
        Enum.find(socket.assigns.providers, fn p -> p.id == provider_id end)

      registry_models =
        case provider do
          nil -> []
          %{} = p -> registry_models_for(p)
        end

      socket =
        socket
        |> assign(:registry_provider, provider)
        |> assign(:registry_models, registry_models)
        |> assign(:registry_filter, "")
        |> assign(:registry_vendor, "")

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  @impl true
  def handle_event("filter_registry", params, socket) do
    # Non-Ash registry browsing: explicitly guard admin.
    if admin?(socket) do
      socket =
        socket
        |> assign(:registry_filter, params["filter"] || "")
        |> assign(:registry_vendor, params["vendor"] || "")

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  # Toggle the registry "Date added" sort. The default (id-ascending) is the
  # starting point; thereafter it flips asc <-> desc.
  @impl true
  def handle_event("sort_registry", _params, socket) do
    if admin?(socket) do
      next = if socket.assigns.registry_sort == :date_asc, do: :date_desc, else: :date_asc
      {:noreply, assign(socket, :registry_sort, next)}
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  @impl true
  def handle_event("pick_registry_model", %{"id" => registry_id}, socket) do
    # Non-Ash registry browsing: explicitly guard admin.
    if admin?(socket) do
      provider = socket.assigns.registry_provider

      entry =
        Enum.find(socket.assigns.registry_models, fn m -> m.id == registry_id end)

      if provider && entry do
        prefill = registry_prefill(provider, entry)

        {:noreply,
         socket
         |> assign(:registry_prefill, prefill)
         |> push_patch(to: ~p"/admin/models/new")}
      else
        {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  @impl true
  def render(assigns) do
    case assigns.live_action do
      action when action in [:new, :edit] -> render_form(assigns)
      :from_registry -> render_registry(assigns)
      _ -> render_index(assigns)
    end
  end

  defp render_registry(assigns) do
    filtered =
      assigns.registry_models
      |> filtered_registry_models(assigns.registry_filter, assigns.registry_vendor)
      |> sort_registry_models(assigns.registry_sort)

    visible = Enum.take(filtered, @registry_render_cap)
    truncated_count = max(length(filtered) - length(visible), 0)

    assigns =
      assigns
      |> assign(:visible_registry_models, visible)
      |> assign(:registry_truncated_count, truncated_count)
      # Vendors are the id prefixes (e.g. "anthropic" in "anthropic/claude-…").
      # Only meaningful for aggregators like OpenRouter; absent for direct
      # providers whose ids have no "/".
      |> assign(:registry_vendors, registry_vendors(assigns.registry_models))

    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center gap-4">
          <.link navigate={~p"/admin/models"} class="btn btn-ghost btn-sm btn-circle">
            <.icon name="lucide-arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-2xl font-bold text-base-content">Add from Registry</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Pick a configured provider, then choose a model from the LLMDB registry to prefill the form.
            </p>
          </div>
        </div>

        <div class="card bg-base-200 border border-base-300">
          <div class="card-body space-y-4">
            <%!-- Step 1: provider --%>
            <div>
              <label class="label font-medium text-sm" for="registry-provider-select">
                Provider
              </label>
              <%!-- phx-change only fires on inputs inside a form --%>
              <form phx-change="select_registry_provider">
                <select
                  id="registry-provider-select"
                  name="provider_id"
                  class="select select-bordered select-sm w-full max-w-md"
                >
                  <option value="">-- select a provider --</option>
                  <option
                    :for={provider <- @providers}
                    value={provider.id}
                    selected={@registry_provider && @registry_provider.id == provider.id}
                  >
                    {provider.name} ({provider.slug})
                  </option>
                </select>
              </form>
            </div>

            <%!-- Step 2: registry models --%>
            <%= if @registry_provider do %>
              <%= if @registry_provider.req_llm_id == "openai_compatible" do %>
                <p class="text-sm text-base-content/60" data-test-registry-empty>
                  Custom OpenAI-compatible endpoints aren't in the registry. Create the model manually via "Add Model".
                </p>
              <% else %>
                <%!-- phx-change only fires on inputs inside a form --%>
                <form phx-change="filter_registry" class="flex flex-wrap items-center gap-3">
                  <input
                    type="text"
                    name="filter"
                    value={@registry_filter}
                    phx-debounce="150"
                    placeholder="Filter by model id…"
                    class="input input-bordered input-sm w-full max-w-md"
                  />
                  <%!-- Vendor sub-filter: only useful for aggregators whose ids
                  are "vendor/model" (e.g. OpenRouter). Hidden when a provider's
                  ids carry no vendor prefix. --%>
                  <select
                    :if={@registry_vendors != []}
                    name="vendor"
                    class="select select-bordered select-sm"
                    data-test-registry-vendor
                  >
                    <option value="">All vendors</option>
                    <option
                      :for={vendor <- @registry_vendors}
                      value={vendor}
                      selected={@registry_vendor == vendor}
                    >
                      {vendor}
                    </option>
                  </select>
                </form>

                <div class="overflow-x-auto max-h-[28rem] overflow-y-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr class="bg-base-300/50">
                        <th>Model ID</th>
                        <th>Name</th>
                        <th class="text-right">Context</th>
                        <th class="text-right">Input $</th>
                        <th class="text-right">Output $</th>
                        <th class="text-right">
                          <button
                            type="button"
                            phx-click="sort_registry"
                            class="inline-flex items-center gap-1 hover:text-base-content cursor-pointer"
                            data-test-registry-sort-date
                          >
                            Date added
                            <.icon
                              :if={@registry_sort in [:date_asc, :date_desc]}
                              name={
                                if @registry_sort == :date_asc,
                                  do: "lucide-chevron-up",
                                  else: "lucide-chevron-down"
                              }
                              class="w-3 h-3"
                            />
                          </button>
                        </th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= if @visible_registry_models == [] do %>
                        <tr>
                          <td colspan="7" class="text-center py-6 text-base-content/50">
                            No registry models match.
                          </td>
                        </tr>
                      <% else %>
                        <tr
                          :for={entry <- @visible_registry_models}
                          class="hover:bg-base-300/30 cursor-pointer"
                          data-test-registry-model={entry.id}
                          data-test-registry-date={entry.release_date || ""}
                          phx-click="pick_registry_model"
                          phx-value-id={entry.id}
                        >
                          <td><code class="text-xs">{entry.id}</code></td>
                          <td class="text-sm">{entry.name || "-"}</td>
                          <td class="text-right font-mono text-xs">
                            {(entry.limits && entry.limits[:context]) || "-"}
                          </td>
                          <td class="text-right font-mono text-xs">
                            {(entry.cost && entry.cost[:input]) || "-"}
                          </td>
                          <td class="text-right font-mono text-xs">
                            {(entry.cost && entry.cost[:output]) || "-"}
                          </td>
                          <td class="text-right font-mono text-xs">
                            {entry.release_date || "-"}
                          </td>
                          <td class="text-right">
                            <span class="btn btn-ghost btn-xs">Use</span>
                          </td>
                        </tr>
                        <%= if @registry_truncated_count > 0 do %>
                          <tr data-test-registry-truncated>
                            <td colspan="7" class="text-center py-4 text-base-content/50 text-sm">
                              {@registry_truncated_count} more — refine the filter
                            </td>
                          </tr>
                        <% end %>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  defp render_index(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">Models</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Manage AI models and their configurations
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button
              type="button"
              phx-click="open_routing_modal"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="lucide-route" class="w-4 h-4" /> Auto-Routing
            </button>
            <.link
              navigate={~p"/admin/models/roles"}
              class="btn btn-ghost btn-sm"
              data-test-roles-link
            >
              <.icon name="lucide-sliders-horizontal" class="w-4 h-4" /> Model roles
            </.link>
            <.link
              navigate={~p"/admin/models/from-registry"}
              class="btn btn-ghost btn-sm"
              data-test-from-registry
            >
              <.icon name="lucide-library" class="w-4 h-4" /> Add from Registry
            </.link>
            <.link navigate={~p"/admin/models/new"} class="btn btn-primary btn-sm">
              <.icon name="lucide-plus" class="w-4 h-4" /> Add Model
            </.link>
          </div>
        </div>

        <%!-- Filters --%>
        <form
          phx-change="apply_filters"
          class="card bg-base-200 border border-base-300"
          data-test-models-filters
        >
          <div class="card-body py-3 flex-row flex-wrap items-end gap-4">
            <div>
              <label class="label label-text text-xs pb-1" for="filter-status">Status</label>
              <select
                id="filter-status"
                name="status"
                class="select select-bordered select-sm"
                data-test-filter-status
              >
                <option value="all" selected={@listing.status == "all"}>All</option>
                <option value="active" selected={@listing.status == "active"}>Active</option>
                <option value="disabled" selected={@listing.status == "disabled"}>Disabled</option>
              </select>
            </div>

            <div>
              <label class="label label-text text-xs pb-1" for="filter-provider">Provider</label>
              <select
                id="filter-provider"
                name="provider"
                class="select select-bordered select-sm"
                data-test-filter-provider
              >
                <option value="">All providers</option>
                <option
                  :for={opt <- @listing.provider_options}
                  value={opt}
                  selected={@listing.provider == opt}
                >
                  {opt}
                </option>
              </select>
            </div>

            <div>
              <span class="label label-text text-xs pb-1">Capabilities</span>
              <div class="flex flex-wrap items-center gap-3 h-8" data-test-filter-caps>
                <label :for={cap <- Listing.caps()} class="label cursor-pointer gap-1 py-0">
                  <input
                    type="checkbox"
                    name="caps[]"
                    value={cap}
                    checked={cap in @listing.caps}
                    class="checkbox checkbox-xs"
                  />
                  <span class="label-text text-xs capitalize">{cap}</span>
                </label>
              </div>
            </div>

            <.link
              :if={filters_active?(@listing)}
              patch={~p"/admin/models"}
              class="btn btn-ghost btn-sm ml-auto"
              data-test-clear-filters
            >
              <.icon name="lucide-x" class="w-4 h-4" /> Clear
            </.link>
          </div>
        </form>

        <%!-- Models Table --%>
        <div class="card bg-base-200 border border-base-300 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm" data-test-models-table>
              <thead>
                <tr class="bg-base-300/50">
                  <.sort_header label="Name" col="name" listing={@listing} />
                  <.sort_header label="Provider" col="provider" listing={@listing} />
                  <th>Model ID</th>
                  <.sort_header label="Status" col="status" listing={@listing} class="text-center" />
                  <th class="text-center">Features</th>
                  <.sort_header
                    label="Input Cost"
                    col="input_cost"
                    listing={@listing}
                    class="text-right"
                  />
                  <.sort_header
                    label="Output Cost"
                    col="output_cost"
                    listing={@listing}
                    class="text-right"
                  />
                  <.sort_header label="Usage" col="usage" listing={@listing} class="text-right" />
                  <th class="text-center">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= if @listing.models == [] do %>
                  <tr>
                    <td colspan="9" class="text-center py-8 text-base-content/50">
                      <%= if @all_models == [] do %>
                        No models configured
                      <% else %>
                        No models match the current filters
                      <% end %>
                    </td>
                  </tr>
                <% else %>
                  <%= for model <- @listing.models do %>
                    <tr class="hover:bg-base-300/30">
                      <td>
                        <div class="flex items-center gap-2">
                          <span class="font-medium">{model.name}</span>
                          <%= if model.internal? do %>
                            <span
                              class="badge badge-neutral badge-xs"
                              data-test-internal-badge={model.key}
                            >
                              Internal
                            </span>
                          <% end %>
                        </div>
                      </td>
                      <td class="text-base-content/70">
                        {Listing.provider_label(model)}
                      </td>
                      <td>
                        <code class="text-xs bg-base-300 px-1 py-0.5 rounded">{model.key}</code>
                      </td>
                      <td class="text-center">
                        <%= if model.active? do %>
                          <span class="badge badge-success badge-sm">Active</span>
                        <% else %>
                          <span class="badge badge-ghost badge-sm">Disabled</span>
                        <% end %>
                      </td>
                      <td class="text-center">
                        <div class="flex items-center justify-center gap-1">
                          <%= if model.supports_search? do %>
                            <span class="tooltip" data-tip="Web Search">
                              <.icon name="lucide-globe" class="w-4 h-4 text-info" />
                            </span>
                          <% end %>
                          <%= if model.supports_reasoning? do %>
                            <span class="tooltip" data-tip="Reasoning">
                              <.icon name="lucide-lightbulb" class="w-4 h-4 text-warning" />
                            </span>
                          <% end %>
                          <%= if model.supports_tools? do %>
                            <span class="tooltip" data-tip="Tools">
                              <.icon name="lucide-wrench" class="w-4 h-4 text-accent" />
                            </span>
                          <% end %>
                          <%= if "image" in (model.output_modalities || []) do %>
                            <span class="tooltip" data-tip="Image Generation">
                              <.icon name="lucide-image" class="w-4 h-4 text-secondary" />
                            </span>
                          <% end %>
                          <%= if "video" in (model.output_modalities || []) do %>
                            <span class="tooltip" data-tip="Video Generation">
                              <.icon name="lucide-film" class="w-4 h-4 text-warning" />
                            </span>
                          <% end %>
                        </div>
                      </td>
                      <td class="text-right font-mono text-sm">
                        {model.input_cost || "-"}
                      </td>
                      <td class="text-right font-mono text-sm">
                        {model.output_cost || "-"}
                      </td>
                      <td class="text-right">
                        <div class="text-sm">{Listing.usage_count(model)} requests</div>
                        <div class="text-xs text-base-content/50">
                          {Formatters.format_cost(Listing.spend(model), 2)}
                        </div>
                      </td>
                      <td>
                        <div class="flex items-center justify-center gap-1">
                          <.link
                            navigate={~p"/admin/models/#{model.id}/edit"}
                            class="btn btn-ghost btn-xs"
                            title="Edit"
                          >
                            <.icon name="lucide-pencil" class="w-4 h-4" />
                          </.link>
                          <button
                            type="button"
                            phx-click="toggle_active"
                            phx-value-id={model.id}
                            class="btn btn-ghost btn-xs"
                            title={if model.active?, do: "Disable", else: "Enable"}
                          >
                            <%= if model.active? do %>
                              <.icon name="lucide-pause" class="w-4 h-4" />
                            <% else %>
                              <.icon name="lucide-play" class="w-4 h-4" />
                            <% end %>
                          </button>
                          <button
                            type="button"
                            phx-click="confirm_delete"
                            phx-value-id={model.id}
                            data-test-delete-confirm={model.id}
                            class="btn btn-ghost btn-xs text-error"
                            title="Delete"
                          >
                            <.icon name="lucide-trash-2" class="w-4 h-4" />
                          </button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>

          <%!-- Pagination --%>
          <div
            class="flex items-center justify-between px-4 py-3 border-t border-base-300 text-sm"
            data-test-models-pagination
          >
            <span class="text-base-content/60">
              {@listing.total} {ngettext("model", "models", @listing.total)}
            </span>
            <div :if={@listing.total_pages > 1} class="flex items-center gap-3">
              <span class="text-base-content/60">
                Page {@listing.page} of {@listing.total_pages}
              </span>
              <div class="join">
                <.link
                  patch={page_path(@listing, @listing.page - 1)}
                  class={[
                    "btn btn-sm join-item",
                    @listing.page <= 1 && "btn-disabled"
                  ]}
                  data-test-page-prev
                >
                  <.icon name="lucide-chevron-left" class="w-4 h-4" />
                </.link>
                <.link
                  patch={page_path(@listing, @listing.page + 1)}
                  class={[
                    "btn btn-sm join-item",
                    @listing.page >= @listing.total_pages && "btn-disabled"
                  ]}
                  data-test-page-next
                >
                  <.icon name="lucide-chevron-right" class="w-4 h-4" />
                </.link>
              </div>
            </div>
          </div>
        </div>
        <%!-- Routing Configuration Modal --%>
        <.modal
          id="routing-modal"
          show={@show_routing_modal}
          on_close="close_routing_modal"
          size={:xl}
        >
          <:title>Auto-Routing Configuration</:title>

          <div class="space-y-4">
            <p class="text-sm text-base-content/60">
              Assign models to routing slots. Each slot maps a specialty (intent) to a tier (complexity).
              A model can appear in multiple slots.
            </p>

            <div class="text-sm text-base-content/50">
              {filled_slot_count(@routing_grid, @specialties, @tiers)} / {length(@specialties) *
                length(@tiers)} chat slots filled
            </div>

            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr class="bg-base-300/50">
                    <th class="w-28">Specialty</th>
                    <th :for={tier <- @tiers} class="text-center">{tier_label(tier)}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={specialty <- @specialties} class="hover:bg-base-300/20">
                    <td class="font-medium text-sm">{specialty_label(specialty)}</td>
                    <td :for={tier <- @tiers} class="text-center">
                      <select
                        id={"routing-select-#{specialty}-#{tier}"}
                        phx-hook=".RoutingSlotSelect"
                        data-specialty={specialty}
                        data-tier={tier}
                        class="select select-bordered select-xs w-full max-w-48"
                      >
                        <option value="">-- empty --</option>
                        <option
                          :for={model <- @active_models}
                          value={model.id}
                          selected={@routing_grid[{specialty, tier}] == model.id}
                        >
                          {model.name}
                        </option>
                      </select>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="divider">Media Models</div>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <%!-- Default Image Model --%>
              <div>
                <label class="label font-medium text-sm">Default Image Model</label>
                <select
                  id="routing-select-image"
                  phx-hook=".RoutingSlotSelect"
                  data-specialty="image"
                  data-tier="standard"
                  class="select select-bordered select-sm w-full"
                >
                  <option value="">-- none --</option>
                  <option
                    :for={model <- @image_models}
                    value={model.id}
                    selected={@routing_grid[{:image, :standard}] == model.id}
                  >
                    {model.name}
                  </option>
                </select>
                <p class="text-xs text-base-content/50 mt-1">
                  Model for image generation (output: image)
                </p>
              </div>

              <%!-- Default Text-to-Video Model --%>
              <div>
                <label class="label font-medium text-sm">Default Text-to-Video Model</label>
                <select
                  id="routing-select-text-to-video"
                  phx-hook=".RoutingSlotSelect"
                  data-specialty="text_to_video"
                  data-tier="standard"
                  class="select select-bordered select-sm w-full"
                >
                  <option value="">-- none --</option>
                  <option
                    :for={model <- @video_models}
                    value={model.id}
                    selected={@routing_grid[{:text_to_video, :standard}] == model.id}
                  >
                    {model.name}
                  </option>
                </select>
                <p class="text-xs text-base-content/50 mt-1">
                  Model for text-to-video generation (output: video)
                </p>
              </div>

              <%!-- Default Image-to-Video Model --%>
              <div>
                <label class="label font-medium text-sm">Default Image-to-Video Model</label>
                <select
                  id="routing-select-image-to-video"
                  phx-hook=".RoutingSlotSelect"
                  data-specialty="image_to_video"
                  data-tier="standard"
                  class="select select-bordered select-sm w-full"
                >
                  <option value="">-- none --</option>
                  <option
                    :for={model <- @image_to_video_models}
                    value={model.id}
                    selected={@routing_grid[{:image_to_video, :standard}] == model.id}
                  >
                    {model.name}
                  </option>
                </select>
                <p class="text-xs text-base-content/50 mt-1">
                  Model for animating images to video (input: image, output: video)
                </p>
              </div>
            </div>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".RoutingSlotSelect">
              export default {
                mounted() {
                  this.el.addEventListener('change', (e) => {
                    this.pushEvent('routing_slot_change', {
                      specialty: this.el.dataset.specialty,
                      tier: this.el.dataset.tier,
                      model_id: e.target.value
                    });
                  });
                }
              }
            </script>
          </div>

          <:actions>
            <button type="button" phx-click="close_routing_modal" class="btn btn-ghost btn-sm">
              Cancel
            </button>
            <button
              type="button"
              phx-click="save_routing"
              disabled={!routing_grid_changed?(@routing_grid, @original_routing_grid)}
              class="btn btn-primary btn-sm"
            >
              Save Configuration
            </button>
          </:actions>
        </.modal>

        <%!-- Delete Confirmation Modal --%>
        <.modal
          :if={@delete_target}
          id="delete-model-modal"
          show={true}
          on_close="cancel_delete"
        >
          <:title>Delete model</:title>

          <div class="space-y-4">
            <p class="text-sm text-base-content/70">
              Delete <span class="font-medium">{@delete_target.model.name}</span>? This cannot be undone.
            </p>

            <div
              class="text-sm text-base-content/60 space-y-1"
              data-test-references
            >
              <p>This model is currently referenced by:</p>
              <ul class="list-disc list-inside">
                <li>Conversations: {@delete_target.counts.conversations}</li>
                <li>Routing slots: {@delete_target.counts.routing_slots}</li>
                <li>Role assignments: {@delete_target.counts.role_assignments}</li>
              </ul>
              <p class="text-xs text-base-content/50">
                If any table still references this model the delete is blocked; deactivate it instead.
              </p>
            </div>
          </div>

          <:actions>
            <button type="button" phx-click="cancel_delete" class="btn btn-ghost btn-sm">
              Cancel
            </button>
            <button
              type="button"
              phx-click="delete"
              phx-value-id={@delete_target.model.id}
              data-test-delete={@delete_target.model.id}
              class="btn btn-error btn-sm"
            >
              Delete
            </button>
          </:actions>
        </.modal>
      </div>
    </Layouts.admin>
    """
  end

  defp render_form(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Header with back link --%>
        <div class="flex items-center gap-4">
          <.link navigate={~p"/admin/models"} class="btn btn-ghost btn-sm btn-circle">
            <.icon name="lucide-arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-2xl font-bold text-base-content">
              {if @live_action == :new, do: "Add New Model", else: "Edit Model"}
            </h1>
            <p class="text-base-content/60 text-sm mt-1">
              {if @live_action == :new,
                do: "Configure a new AI model",
                else: "Update model configuration"}
            </p>
          </div>
        </div>

        <%!-- Form Card --%>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <.form
              for={@form}
              id="model-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-6"
            >
              <%!-- Basic Info Section --%>
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Basic Information</h3>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 [&_.fieldset]:mb-0">
                  <.input field={@form[:name]} label="Name" placeholder="e.g., GPT-4o" />
                  <.input
                    field={@form[:provider]}
                    label="Provider"
                    placeholder="e.g., openai, anthropic, google"
                  />
                  <.input
                    field={@form[:model_provider_id]}
                    type="select"
                    label="Linked Provider"
                    options={provider_options(@providers)}
                  />
                  <div class="md:col-span-2 [&_.fieldset]:mb-0">
                    <.input
                      field={@form[:key]}
                      label="Model ID / Key"
                      placeholder="e.g., gpt-4o or openai/gpt-4o"
                    />
                    <p class="text-xs text-base-content/50 -mt-1">
                      The API model identifier used when calling the provider
                    </p>
                  </div>
                </div>
              </div>

              <div class="divider"></div>

              <%!-- Pricing Section --%>
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Pricing</h3>
                <div class="grid grid-cols-1 md:grid-cols-4 gap-4 [&_.fieldset]:mb-0">
                  <.input
                    field={@form[:input_cost]}
                    label="Input Cost (per 1M tokens)"
                    placeholder="e.g., 2.50"
                  />
                  <.input
                    field={@form[:output_cost]}
                    label="Output Cost (per 1M tokens)"
                    placeholder="e.g., 10.00"
                  />
                  <.input
                    field={@form[:context_window]}
                    type="number"
                    label="Context Window"
                    placeholder="e.g., 128000"
                  />
                </div>
              </div>

              <div class="divider"></div>

              <%!-- Modalities Section --%>
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Modalities</h3>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <.modality_checkboxes
                    label="Input Modalities"
                    field={@form[:input_modalities]}
                    options={["text", "image", "file"]}
                  />
                  <.modality_checkboxes
                    label="Output Modalities"
                    field={@form[:output_modalities]}
                    options={["text", "image", "video"]}
                  />
                </div>
              </div>

              <div class="divider"></div>

              <%!-- Provider Routing Section --%>
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Provider routing</h3>
                <%= if @openrouter_provider_slugs == [] do %>
                  <p class="text-sm text-base-content/60">
                    Sync OpenRouter providers first to configure denied providers.
                  </p>
                <% else %>
                  <.modality_checkboxes
                    label="Denied providers (OpenRouter)"
                    field={@form[:denied_providers]}
                    options={@openrouter_provider_slugs}
                    allow_empty={true}
                  />
                  <p class="text-xs text-base-content/50 mt-2">
                    Checked providers are excluded when this model is served through OpenRouter.
                  </p>
                <% end %>
              </div>

              <div class="divider"></div>

              <%!-- Descriptions Section with Language Tabs --%>
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Descriptions</h3>

                <%!-- Language Tabs --%>
                <div class="tabs tabs-boxed mb-4 w-fit">
                  <button
                    type="button"
                    phx-click="switch_desc_tab"
                    phx-value-tab="en"
                    class={"tab #{if @desc_tab == "en", do: "tab-active"}"}
                  >
                    English
                  </button>
                  <button
                    type="button"
                    phx-click="switch_desc_tab"
                    phx-value-tab="de"
                    class={"tab #{if @desc_tab == "de", do: "tab-active"}"}
                  >
                    Deutsch
                  </button>
                </div>

                <div class="space-y-4 [&_.fieldset]:mb-0">
                  <div>
                    <.input
                      name={"form[short_description_translations][#{@desc_tab}]"}
                      value={get_translation_value(@form, :short_description_translations, @desc_tab)}
                      label={
                        "Short Description (#{if @desc_tab == "en", do: "English", else: "German"})"
                      }
                      placeholder="Brief description (1-2 sentences)"
                    />
                    <p class="text-xs text-base-content/50 -mt-1">
                      Shown in model selector and cards
                    </p>
                  </div>

                  <div>
                    <.input
                      type="textarea"
                      name={"form[detailed_description_translations][#{@desc_tab}]"}
                      value={
                        get_translation_value(
                          @form,
                          :detailed_description_translations,
                          @desc_tab
                        )
                      }
                      label={
                        "Detailed Description (#{if @desc_tab == "en", do: "English", else: "German"})"
                      }
                      placeholder="Full description for model detail view"
                      class="textarea h-32"
                    />
                    <p class="text-xs text-base-content/50 -mt-1">
                      Shown on model detail page
                    </p>
                  </div>
                </div>
              </div>

              <div class="divider"></div>

              <%!-- Capabilities Section --%>
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Capabilities</h3>
                <div class="flex flex-wrap gap-6 [&_.fieldset]:mb-0">
                  <.input type="checkbox" field={@form[:supports_tools?]} label="Tool Calling" />
                  <.input type="checkbox" field={@form[:supports_search?]} label="Web Search" />
                  <.input type="checkbox" field={@form[:supports_reasoning?]} label="Reasoning" />
                </div>
              </div>

              <div class="divider"></div>

              <%!-- Status Section --%>
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Status</h3>
                <div class="flex flex-wrap gap-6 [&_.fieldset]:mb-0">
                  <.input
                    type="checkbox"
                    field={@form[:active?]}
                    label="Active"
                    class="checkbox checkbox-primary"
                  />
                </div>
              </div>

              <%!-- Form Actions --%>
              <div class="flex items-center justify-end gap-3 pt-4 border-t border-base-300">
                <.link navigate={~p"/admin/models"} class="btn btn-ghost">
                  Cancel
                </.link>
                <button type="submit" class="btn btn-primary">
                  {if @live_action == :new, do: "Create Model", else: "Save Changes"}
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  attr :label, :string, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true
  # Opt-in only. When true, a hidden sentinel sends the field key even when every
  # checkbox is unchecked, so an all-unchecked submit clears the list to [] instead
  # of omitting the key (which Ash would treat as "unchanged"). Modality fields do
  # not set this, so their behavior is unaffected.
  attr :allow_empty, :boolean, default: false

  defp modality_checkboxes(assigns) do
    ~H"""
    <fieldset>
      <legend class="label font-medium">{@label}</legend>
      <div class="flex flex-wrap gap-4 mt-2">
        <input :if={@allow_empty} type="hidden" name={@field.name <> "[]"} value="" />
        <label :for={opt <- @options} class="label cursor-pointer gap-2">
          <input
            type="checkbox"
            name={@field.name <> "[]"}
            value={opt}
            checked={opt in (@field.value || [])}
            class="checkbox checkbox-sm"
          />
          <span class="label-text">{String.capitalize(opt)}</span>
        </label>
      </div>
    </fieldset>
    """
  end

  # ============================================================================
  # Index Listing Helpers (sortable header + filter/sort/page URL building)
  # ============================================================================

  attr :label, :string, required: true
  attr :col, :string, required: true
  attr :listing, :map, required: true
  attr :class, :string, default: nil

  defp sort_header(assigns) do
    ~H"""
    <th class={@class}>
      <.link
        patch={sort_path(@listing, @col)}
        class="inline-flex items-center gap-1 hover:text-base-content cursor-pointer"
        data-test-sort={@col}
      >
        {@label}
        <.icon
          :if={@listing.sort == @col}
          name={if @listing.dir == "asc", do: "lucide-chevron-up", else: "lucide-chevron-down"}
          class="w-3 h-3"
        />
      </.link>
    </th>
    """
  end

  # Rebuild the URL query params from the computed listing so sort/page links
  # preserve the active filters.
  defp listing_to_params(listing) do
    %{
      "status" => listing.status,
      "provider" => listing.provider,
      "caps" => Enum.join(listing.caps, ","),
      "sort" => listing.sort,
      "dir" => listing.dir,
      "page" => to_string(listing.page)
    }
  end

  defp list_path(params) do
    query =
      params
      |> Enum.reject(fn {k, v} -> blank_or_default?(k, v) end)
      |> Enum.sort()

    ~p"/admin/models?#{query}"
  end

  defp sort_path(listing, column) do
    dir = Listing.toggle_dir(listing.sort, listing.dir, column)

    listing
    |> listing_to_params()
    |> Map.merge(%{"sort" => column, "dir" => dir, "page" => "1"})
    |> list_path()
  end

  defp page_path(listing, page) do
    page = page |> max(1) |> min(listing.total_pages)

    listing
    |> listing_to_params()
    |> Map.put("page", to_string(page))
    |> list_path()
  end

  # Keep the URL clean: drop empty values and defaults so the bare /admin/models
  # path represents the unfiltered, name-ascending, first-page view.
  defp blank_or_default?(_k, v) when v in [nil, ""], do: true
  defp blank_or_default?("status", "all"), do: true
  defp blank_or_default?("sort", "name"), do: true
  defp blank_or_default?("dir", "asc"), do: true
  defp blank_or_default?("page", "1"), do: true
  defp blank_or_default?(_k, _v), do: false

  defp filters_active?(listing) do
    listing.status != "all" or listing.provider != "" or listing.caps != [] or
      listing.sort != "name" or listing.dir != "asc"
  end

  defp admin?(socket), do: socket.assigns.current_user.is_admin == true

  defp delete_blocked_message(counts) do
    "This model is referenced (conversations: #{counts.conversations}, " <>
      "routing slots: #{counts.routing_slots}, role assignments: #{counts.role_assignments}) " <>
      "and cannot be deleted. Deactivate it instead."
  end

  # ============================================================================
  # Registry Picker Helpers
  # ============================================================================

  # OpenAI-compatible custom endpoints aren't in the packaged LLMDB registry,
  # so there's nothing to browse; the UI hints to create the model manually.
  defp registry_models_for(%{req_llm_id: "openai_compatible"}), do: []

  defp registry_models_for(%{req_llm_id: req_llm_id}) do
    case safe_provider_atom(req_llm_id) do
      nil ->
        []

      atom ->
        atom
        |> LLMDB.models()
        |> Enum.sort_by(& &1.id)
    end
  end

  # req_llm_id is admin-authored and corresponds to a registered ReqLLM
  # provider; convert via existing-atom only so a stale/unknown id can never
  # exhaust the atom table.
  defp safe_provider_atom(req_llm_id) when is_binary(req_llm_id) do
    String.to_existing_atom(req_llm_id)
  rescue
    ArgumentError -> nil
  end

  defp filtered_registry_models(models, filter, vendor) do
    models
    |> filter_registry_by_text(filter)
    |> filter_registry_by_vendor(vendor)
  end

  defp filter_registry_by_text(models, ""), do: models

  defp filter_registry_by_text(models, filter) do
    needle = String.downcase(filter)
    Enum.filter(models, fn m -> String.contains?(String.downcase(m.id), needle) end)
  end

  defp filter_registry_by_vendor(models, ""), do: models

  defp filter_registry_by_vendor(models, vendor) do
    Enum.filter(models, fn m -> registry_vendor(m.id) == vendor end)
  end

  # Distinct id prefixes (the "vendor" in "vendor/model"), sorted. Empty when no
  # id contains a "/", i.e. for direct (non-aggregator) providers.
  defp registry_vendors(models) do
    models
    |> Enum.map(&registry_vendor(&1.id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp registry_vendor(id) when is_binary(id) do
    case String.split(id, "/", parts: 2) do
      [vendor, _rest] -> vendor
      _ -> nil
    end
  end

  defp registry_vendor(_), do: nil

  # Sort the registry list. `release_date` is an ISO "YYYY-MM-DD" string, so a
  # lexicographic sort is chronological; entries without a date sort last in
  # both directions. Default is id-ascending (the load order).
  defp sort_registry_models(models, :date_asc), do: by_release_date(models, :asc)
  defp sort_registry_models(models, :date_desc), do: by_release_date(models, :desc)
  defp sort_registry_models(models, _), do: Enum.sort_by(models, & &1.id)

  defp by_release_date(models, dir) do
    {dated, undated} = Enum.split_with(models, &present_release_date?/1)
    Enum.sort_by(dated, & &1.release_date, dir) ++ undated
  end

  defp present_release_date?(%{release_date: d}), do: is_binary(d) and d != ""
  defp present_release_date?(_), do: false

  # Build create-form params from a registry entry, mapping defensively: any
  # field may be nil and is then left blank on the form.
  defp registry_prefill(provider, %LLMDB.Model{} = entry) do
    limits = entry.limits || %{}
    cost = entry.cost || %{}
    modalities = entry.modalities || %{}
    capabilities = entry.capabilities || %{}
    reasoning = Map.get(capabilities, :reasoning) || %{}

    %{}
    |> put_present("name", entry.name || entry.id)
    |> Map.put("key", "#{provider.slug}:#{entry.id}")
    |> Map.put("model_provider_id", provider.id)
    |> put_present("context_window", to_string_or_nil(Map.get(limits, :context)))
    |> put_present("input_cost", to_string_or_nil(Map.get(cost, :input)))
    |> put_present("output_cost", to_string_or_nil(Map.get(cost, :output)))
    |> Map.put("input_modalities", registry_modalities(Map.get(modalities, :input)))
    |> Map.put("output_modalities", registry_modalities(Map.get(modalities, :output)))
    |> Map.put("supports_reasoning?", to_string(Map.get(reasoning, :enabled) == true))
    |> put_llm_metadata(limits)
  end

  defp put_present(params, _key, nil), do: params
  defp put_present(params, _key, ""), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  # Map registry modality atoms (:text, :image, :file) to the model resource's
  # string lists, keeping only values the resource recognizes.
  defp registry_modalities(nil), do: ["text"]

  defp registry_modalities(list) when is_list(list) do
    allowed = ["text", "image", "file", "video"]

    mapped =
      list
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 in allowed))

    if mapped == [], do: ["text"], else: mapped
  end

  defp registry_modalities(_), do: ["text"]

  defp put_llm_metadata(params, limits) do
    output_limit = Map.get(limits, :output)

    if is_nil(output_limit) do
      params
    else
      Map.put(params, "llm_metadata", %{"output_limit" => output_limit})
    end
  end

  defp get_translation_value(form, field, locale) do
    translations = form[field].value || %{}

    case translations do
      map when is_map(map) -> Map.get(map, locale, "")
      _ -> ""
    end
  end

  # ============================================================================
  # Routing Grid Helpers
  # ============================================================================

  defp list_active_models do
    require Ash.Query

    Model
    |> Ash.Query.for_read(:list_active)
    |> Ash.read!(authorize?: false)
  end

  defp list_models_by_output_modality(modality) do
    require Ash.Query

    Model
    |> Ash.Query.filter(
      active? == true and fragment("? @> ARRAY[?]::text[]", output_modalities, ^modality)
    )
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp list_image_to_video_models do
    require Ash.Query

    Model
    |> Ash.Query.filter(
      active? == true and
        fragment("? @> ARRAY['video']::text[]", output_modalities) and
        fragment("? @> ARRAY['image']::text[]", input_modalities)
    )
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp build_routing_grid do
    # Initialize all chat slots to nil
    empty =
      for s <- @specialties, t <- @tiers, into: %{} do
        {{s, t}, nil}
      end

    # Add media slots
    media_empty =
      for s <- @media_specialties, into: %{} do
        {{s, :standard}, nil}
      end

    empty = Map.merge(empty, media_empty)

    # Fill from routing slots
    case Magus.Chat.list_routing_slots(authorize?: false) do
      {:ok, slots} ->
        Enum.reduce(slots, empty, fn slot, grid ->
          Map.put(grid, {slot.specialty, slot.tier}, slot.model_id)
        end)

      _ ->
        empty
    end
  end

  defp delete_routing_slot(specialty, tier) do
    require Ash.Query

    case RoutingSlot
         |> Ash.Query.filter(specialty == ^specialty and tier == ^tier)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:ok, :noop}
      {:ok, slot} -> Ash.destroy(slot, authorize?: false)
      {:error, reason} -> {:error, reason}
    end
  end

  defp routing_grid_changed?(grid, original) do
    grid != original
  end

  defp filled_slot_count(grid, specialties, tiers) do
    chat_slots = for s <- specialties, t <- tiers, do: {s, t}
    Enum.count(chat_slots, fn slot -> grid[slot] != nil end)
  end

  defp validate_routing_enum(value, allowed) do
    atom = String.to_existing_atom(value)
    if atom in allowed, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp specialty_label(:general), do: "General"
  defp specialty_label(:coding), do: "Coding"
  defp specialty_label(:search), do: "Search"
  defp specialty_label(:reasoning), do: "Reasoning"
  defp specialty_label(:creative), do: "Creative"
  defp specialty_label(:image), do: "Image"
  defp specialty_label(:text_to_video), do: "Text to Video"
  defp specialty_label(:image_to_video), do: "Image to Video"

  defp tier_label(:simple), do: "Simple"
  defp tier_label(:standard), do: "Standard"
  defp tier_label(:complex), do: "Complex"
end
