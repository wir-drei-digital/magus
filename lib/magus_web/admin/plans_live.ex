defmodule MagusWeb.Admin.PlansLive do
  @moduledoc """
  Admin view for managing usage plans.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts
  alias Magus.Usage.Policy

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Plans")
      |> assign(:current_path, "/admin/plans")
      |> assign(:billing_fields?, Magus.Usage.billing_edition?())
      |> load_plans()

    {:ok, socket}
  end

  defp load_plans(socket) do
    require Ash.Query

    plans =
      Policy
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(sort_order: :asc)
      |> Ash.read!(authorize?: false)

    # One grouped count instead of loading every subscription row per plan.
    counts = Magus.Usage.AdminStats.plan_subscriber_counts()

    plans_with_counts =
      Enum.map(plans, fn plan ->
        Map.put(plan, :subscriber_count, Map.get(counts, plan.id, 0))
      end)

    assign(socket, :plans, plans_with_counts)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Plans")
    |> assign(:plan, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    form =
      Policy
      |> AshPhoenix.Form.for_create(:create, authorize?: false, forms: [auto?: true])
      |> to_form()

    socket
    |> assign(:page_title, "New Plan")
    |> assign(:plan, nil)
    |> assign(:form, form)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Ash.get(Policy, id, authorize?: false) do
      {:ok, plan} ->
        form =
          plan
          |> AshPhoenix.Form.for_update(:update, authorize?: false, forms: [auto?: true])
          |> to_form()

        socket
        |> assign(:page_title, "Edit #{plan.name}")
        |> assign(:plan, plan)
        |> assign(:form, form)

      {:error, _} ->
        socket
        |> put_flash(:error, "Plan not found")
        |> push_navigate(to: ~p"/admin/plans")
    end
  end

  # ============================================================================
  # Form Events
  # ============================================================================

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form.source, params)
    {:noreply, assign(socket, :form, to_form(form))}
  end

  @impl true
  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _plan} ->
        action = if socket.assigns.live_action == :new, do: "created", else: "updated"

        {:noreply,
         socket
         |> put_flash(:info, "Plan #{action} successfully")
         |> push_navigate(to: ~p"/admin/plans")}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    case Ash.get(Policy, id, authorize?: false) do
      {:ok, plan} ->
        result =
          plan
          |> Ash.Changeset.for_update(:update, %{is_active: !plan.is_active})
          |> Ash.update(authorize?: false)

        case result do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Plan #{if plan.is_active, do: "deactivated", else: "activated"}"
             )
             |> load_plans()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update plan")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Plan not found")}
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    if assigns.live_action in [:new, :edit] do
      render_form(assigns)
    else
      render_index(assigns)
    end
  end

  defp render_index(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">Plans</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Manage subscription plans and their limits
            </p>
          </div>
          <.link navigate={~p"/admin/plans/new"} class="btn btn-primary btn-sm">
            <.icon name="lucide-plus" class="w-4 h-4" /> Add Plan
          </.link>
        </div>

        <%!-- Plans Table --%>
        <div class="card bg-base-200 border border-base-300 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="bg-base-300/50">
                  <th>Plan</th>
                  <th class="text-center">Status</th>
                  <th class="text-right">Price</th>
                  <th class="text-right">Storage</th>
                  <th class="text-center">Modes</th>
                  <th class="text-right">Subscribers</th>
                  <th class="text-center">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= if @plans == [] do %>
                  <tr>
                    <td colspan="7" class="text-center py-8 text-base-content/50">
                      No plans configured
                    </td>
                  </tr>
                <% else %>
                  <%= for plan <- @plans do %>
                    <tr class="hover:bg-base-300/30">
                      <td>
                        <div>
                          <span class="font-medium">{plan.name}</span>
                          <div class="text-xs text-base-content/50">
                            <code class="bg-base-300 px-1 py-0.5 rounded">{plan.key}</code>
                          </div>
                        </div>
                      </td>
                      <td class="text-center">
                        <%= if plan.is_active do %>
                          <span class="badge badge-success badge-sm">Active</span>
                        <% else %>
                          <span class="badge badge-ghost badge-sm">Inactive</span>
                        <% end %>
                      </td>
                      <td class="text-right font-mono text-sm">
                        {format_price(plan.price_monthly_cents)}
                      </td>
                      <td class="text-right font-mono text-sm">
                        {format_bytes(plan.storage_bytes)}
                      </td>
                      <td class="text-center">
                        <div class="flex items-center justify-center gap-1">
                          <span
                            class={"badge badge-xs " <> if(plan.image_generation_enabled, do: "badge-success", else: "badge-ghost")}
                            title={"Image generation: " <> if(plan.image_generation_enabled, do: "enabled", else: "disabled")}
                          >
                            img
                          </span>
                          <span
                            class={"badge badge-xs " <> if(plan.video_generation_enabled, do: "badge-success", else: "badge-ghost")}
                            title={"Video generation: " <> if(plan.video_generation_enabled, do: "enabled", else: "disabled")}
                          >
                            vid
                          </span>
                        </div>
                      </td>
                      <td class="text-right">
                        <span class={[
                          "badge badge-sm",
                          if(plan.subscriber_count > 0, do: "badge-info", else: "badge-ghost")
                        ]}>
                          {plan.subscriber_count}
                        </span>
                      </td>
                      <td>
                        <div class="flex items-center justify-center gap-1">
                          <.link
                            navigate={~p"/admin/plans/#{plan.id}/edit"}
                            class="btn btn-ghost btn-xs"
                            title="Edit"
                          >
                            <.icon name="lucide-pencil" class="w-4 h-4" />
                          </.link>
                          <button
                            type="button"
                            phx-click="toggle_active"
                            phx-value-id={plan.id}
                            class="btn btn-ghost btn-xs"
                            title={if plan.is_active, do: "Deactivate", else: "Activate"}
                          >
                            <%= if plan.is_active do %>
                              <.icon name="lucide-pause" class="w-4 h-4" />
                            <% else %>
                              <.icon name="lucide-play" class="w-4 h-4" />
                            <% end %>
                          </button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
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
          <.link navigate={~p"/admin/plans"} class="btn btn-ghost btn-sm btn-circle">
            <.icon name="lucide-arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-2xl font-bold text-base-content">
              {if @live_action == :new, do: "Add New Plan", else: "Edit Plan"}
            </h1>
            <p class="text-base-content/60 text-sm mt-1">
              {if @live_action == :new,
                do: "Configure a new subscription plan",
                else: "Update plan configuration"}
            </p>
          </div>
        </div>

        <%!-- Form Card --%>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-6">
              <%!-- Basic Info Section --%>
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Basic Information</h3>
                <div class="grid grid-cols-1 md:grid-cols-3 gap-4 [&_.fieldset]:mb-0">
                  <.input
                    field={@form[:key]}
                    label="Key"
                    placeholder="e.g., free, starter, pro"
                    disabled={@live_action == :edit}
                  />
                  <.input field={@form[:name]} label="Name" placeholder="e.g., Free, Starter, Pro" />
                  <.input
                    :if={@billing_fields?}
                    field={@form[:price_monthly_cents]}
                    type="number"
                    label="Price (cents/month)"
                    placeholder="0"
                    min="0"
                    step="1"
                  />
                </div>
                <div class="[&_.fieldset]:mb-0">
                  <.input
                    field={@form[:description]}
                    label="Description"
                    placeholder="Brief plan description"
                  />
                </div>
              </div>

              <div class="divider"></div>

              <%!-- Storage Limits --%>
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Storage</h3>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 [&_.fieldset]:mb-0">
                  <div>
                    <.input
                      field={@form[:storage_bytes]}
                      type="number"
                      label="Total storage (bytes)"
                      placeholder="0"
                      min="0"
                    />
                    <p class="text-xs text-base-content/50 -mt-1">
                      = {format_bytes(@form[:storage_bytes].value)}
                    </p>
                  </div>
                  <div>
                    <.input
                      field={@form[:max_upload_bytes]}
                      type="number"
                      label="Max upload size (bytes)"
                      placeholder="0"
                      min="0"
                    />
                    <p class="text-xs text-base-content/50 -mt-1">
                      = {format_bytes(@form[:max_upload_bytes].value)} per file
                    </p>
                  </div>
                </div>
              </div>

              <div class="divider"></div>

              <%!-- Settings (billing fields shown only when billing is configured) --%>
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Settings</h3>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 [&_.fieldset]:mb-0">
                  <.input
                    :if={@billing_fields?}
                    field={@form[:stripe_price_id_monthly]}
                    label="Stripe Price ID (monthly)"
                    placeholder="price_..."
                    class="w-full input font-mono text-sm"
                  />
                  <.input
                    :if={@billing_fields?}
                    field={@form[:stripe_price_id_yearly]}
                    label="Stripe Price ID (yearly)"
                    placeholder="price_..."
                    class="w-full input font-mono text-sm"
                  />
                  <.input
                    field={@form[:max_routing_tier]}
                    type="select"
                    label="Max routing tier"
                    options={[Simple: :simple, Standard: :standard, Complex: :complex]}
                  />
                  <.input
                    field={@form[:sort_order]}
                    type="number"
                    label="Sort order"
                    placeholder="0"
                  />
                </div>

                <div class="flex flex-wrap gap-6 mt-4 [&_.fieldset]:mb-0">
                  <.input
                    type="checkbox"
                    field={@form[:is_active]}
                    label="Active (visible to new subscribers)"
                  />
                  <.input
                    type="checkbox"
                    field={@form[:image_generation_enabled]}
                    label="Image generation enabled"
                  />
                  <.input
                    type="checkbox"
                    field={@form[:video_generation_enabled]}
                    label="Video generation enabled"
                  />
                </div>
              </div>

              <%!-- Form Actions --%>
              <div class="flex items-center justify-end gap-3 pt-4 border-t border-base-300">
                <.link navigate={~p"/admin/plans"} class="btn btn-ghost">
                  Cancel
                </.link>
                <button type="submit" class="btn btn-primary">
                  {if @live_action == :new, do: "Create Plan", else: "Save Changes"}
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  defp format_price(cents) when is_integer(cents) and cents > 0 do
    "CHF #{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  end

  defp format_price(_), do: "Free"

  defp format_bytes(bytes), do: MagusWeb.Formatters.format_bytes(bytes)
end
