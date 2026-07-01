defmodule MagusWeb.Admin.UserDetailLive do
  @moduledoc """
  Admin view for viewing and managing individual user details.

  Shows:
  - User info card (email, name, timezone, admin status)
  - Subscription card with plan selector
  - Usage stats (storage and PAYG spend)
  - 24-hour message activity chart
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts
  alias Magus.Accounts.User
  alias Magus.Usage.Calculator

  @impl true
  def mount(%{"id" => user_id}, _session, socket) do
    case Ash.get(User, user_id, authorize?: false) do
      {:ok, user} ->
        socket =
          socket
          |> assign(:page_title, "User: #{user.email}")
          |> assign(:current_path, "/admin/users")
          |> assign(:user, user)
          |> assign(:show_password, false)
          |> load_subscription(user.id)
          |> load_plans()
          |> load_usage_stats(user)

        {:ok, socket}

      {:error, _} ->
        socket =
          socket
          |> put_flash(:error, "User not found")
          |> push_navigate(to: ~p"/admin/users")

        {:ok, socket}
    end
  end

  defp load_subscription(socket, user_id) do
    case Magus.Usage.get_user_subscription(user_id,
           load: [:usage_plan],
           authorize?: false
         ) do
      {:ok, subscription} ->
        socket
        |> assign(:subscription, subscription)
        |> assign(:selected_new_plan_id, nil)

      {:error, _} ->
        socket
        |> assign(:subscription, nil)
        |> assign(:selected_new_plan_id, nil)
    end
  end

  defp load_plans(socket) do
    plans = Magus.Usage.list_active_plans!(authorize?: false)
    assign(socket, :plans, plans)
  end

  defp load_usage_stats(socket, user) do
    timezone = user.timezone || "Etc/UTC"
    stats = Calculator.get_usage_stats(user.id, timezone)
    limits = Calculator.get_effective_limits(user.id)

    socket
    |> assign(:usage_stats, stats)
    |> assign(:limits, limits)
  end

  @impl true
  def handle_event("change_plan", %{"plan_id" => plan_id}, socket) do
    subscription = socket.assigns.subscription

    with true <- not is_nil(subscription),
         {:ok, new_plan} <- Magus.Usage.get_usage_plan(plan_id, authorize?: false) do
      result =
        if new_plan.key == "free" do
          Magus.Usage.downgrade_to_free(subscription, %{usage_plan_id: plan_id},
            authorize?: false
          )
        else
          Magus.Usage.upgrade_subscription(
            subscription,
            %{usage_plan_id: plan_id, status: :active},
            authorize?: false
          )
        end

      case result do
        {:ok, _} ->
          socket =
            socket
            |> put_flash(:info, "Plan updated to #{new_plan.name}")
            |> load_subscription(socket.assigns.user.id)
            |> load_usage_stats(socket.assigns.user)

          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update plan")}
      end
    else
      false ->
        {:noreply, put_flash(socket, :error, "User has no subscription")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid plan selected")}
    end
  end

  @impl true
  def handle_event("select_new_plan", %{"plan_id" => ""}, socket) do
    {:noreply, assign(socket, :selected_new_plan_id, nil)}
  end

  def handle_event("select_new_plan", %{"plan_id" => plan_id}, socket) do
    {:noreply, assign(socket, :selected_new_plan_id, plan_id)}
  end

  @impl true
  def handle_event("create_subscription", _params, socket) do
    plan_id = socket.assigns.selected_new_plan_id
    user = socket.assigns.user

    with true <- not is_nil(plan_id),
         {:ok, plan} <- Magus.Usage.get_usage_plan(plan_id, authorize?: false) do
      result =
        Magus.Usage.create_user_subscription(
          %{
            user_id: user.id,
            usage_plan_id: plan_id,
            status: :active
          },
          authorize?: false
        )

      case result do
        {:ok, _subscription} ->
          socket =
            socket
            |> put_flash(:info, "Subscription created with #{plan.name}")
            |> load_subscription(user.id)
            |> load_usage_stats(user)

          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to create subscription")}
      end
    else
      false ->
        {:noreply, put_flash(socket, :error, "Please select a plan")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid plan selected")}
    end
  end

  @impl true
  def handle_event("toggle_password", _params, socket) do
    {:noreply, assign(socket, :show_password, !socket.assigns.show_password)}
  end

  @impl true
  def handle_event("delete_test_user", _params, socket) do
    user = socket.assigns.user

    cond do
      not user.test_account ->
        {:noreply, put_flash(socket, :error, "Only demo accounts can be deleted here.")}

      true ->
        case Magus.Accounts.AccountDeletion.execute(user) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Deleted demo account #{user.email}")
             |> push_navigate(to: ~p"/admin/users")}

          {:error, :sole_admin_workspaces, _workspaces} ->
            {:noreply,
             put_flash(socket, :error, "Can't delete: user is the sole admin of a workspace.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Back button and header --%>
        <div class="flex items-center gap-4">
          <.link navigate={~p"/admin/users"} class="btn btn-ghost btn-sm">
            <.icon name="lucide-arrow-left" class="w-4 h-4" /> Back to Users
          </.link>
        </div>

        <%!-- User Info Card --%>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <h2 class="card-title">User Information</h2>

            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mt-4">
              <div>
                <p class="text-xs text-base-content/60">Email</p>
                <p class="font-medium">{@user.email}</p>
              </div>
              <div>
                <p class="text-xs text-base-content/60">Display Name</p>
                <p class="font-medium">{@user.display_name || "-"}</p>
              </div>
              <div>
                <p class="text-xs text-base-content/60">Joined</p>
                <p class="font-medium">{format_date(@user.inserted_at)}</p>
              </div>
              <div>
                <p class="text-xs text-base-content/60">Timezone</p>
                <p class="font-medium">{@user.timezone || "Not set"}</p>
              </div>
            </div>

            <div class="flex gap-2 mt-4">
              <%= if @user.is_admin do %>
                <span class="badge badge-primary">Admin</span>
              <% end %>
              <%= if @user.confirmed_at do %>
                <span class="badge badge-success">Confirmed</span>
              <% else %>
                <span class="badge badge-warning">Unconfirmed</span>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Demo Account Card --%>
        <div :if={@user.test_account} class="card bg-base-200 border border-info/40">
          <div class="card-body">
            <div class="flex items-start justify-between gap-4">
              <div>
                <h2 class="card-title">
                  <.icon name="lucide-flask-conical" class="w-5 h-5 text-info" /> Demo Account
                </h2>
                <p class="text-sm text-base-content/60">
                  Demo account — unlimited usage, no Stripe.
                </p>
              </div>
              <button
                type="button"
                phx-click="delete_test_user"
                data-confirm={"Permanently delete #{@user.email} and all its data? This cannot be undone."}
                class="btn btn-error btn-sm"
              >
                <.icon name="lucide-trash-2" class="w-4 h-4" /> Delete account
              </button>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 mt-4">
              <div>
                <p class="text-xs text-base-content/60">Password</p>
                <div class="flex items-center gap-2 mt-0.5">
                  <span class="font-mono font-medium">
                    <%= cond do %>
                      <% is_nil(@user.test_account_password) -> %>
                        <span class="text-base-content/40">not stored</span>
                      <% @show_password -> %>
                        {@user.test_account_password}
                      <% true -> %>
                        ••••••••••
                    <% end %>
                  </span>
                  <button
                    :if={@user.test_account_password}
                    type="button"
                    phx-click="toggle_password"
                    class="btn btn-ghost btn-xs"
                    title={if @show_password, do: "Hide", else: "Show"}
                  >
                    <.icon
                      name={if @show_password, do: "lucide-eye-off", else: "lucide-eye"}
                      class="w-4 h-4"
                    />
                  </button>
                </div>
              </div>
              <div>
                <p class="text-xs text-base-content/60">Deletes on</p>
                <p class="font-medium">{format_period_end(@user.test_account_expires_at)}</p>
              </div>
            </div>
          </div>
        </div>

        <%!-- Subscription Card --%>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <h2 class="card-title">Subscription</h2>

            <%= if @subscription do %>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mt-4">
                <div>
                  <p class="text-xs text-base-content/60">Current Plan</p>
                  <p class="font-medium">{@subscription.usage_plan.name}</p>
                </div>
                <div>
                  <p class="text-xs text-base-content/60">Status</p>
                  <.status_badge status={@subscription.status} />
                </div>
                <div>
                  <p class="text-xs text-base-content/60">Change Plan</p>
                  <form phx-change="change_plan">
                    <select
                      class="select select-bordered select-sm w-full max-w-xs"
                      name="plan_id"
                    >
                      <%= for plan <- @plans do %>
                        <option value={plan.id} selected={plan.id == @subscription.usage_plan_id}>
                          {plan.name}
                        </option>
                      <% end %>
                    </select>
                  </form>
                </div>
                <div>
                  <p class="text-xs text-base-content/60">Period End</p>
                  <p class="font-medium">
                    {format_period_end(@subscription.current_period_end)}
                  </p>
                </div>
              </div>
            <% else %>
              <div class="mt-4">
                <p class="text-base-content/60 mb-3">No subscription found. Create one:</p>
                <form
                  phx-change="select_new_plan"
                  phx-submit="create_subscription"
                  class="flex items-center gap-3"
                >
                  <select
                    class="select select-bordered select-sm w-full max-w-xs"
                    name="plan_id"
                  >
                    <option value="" disabled selected={is_nil(@selected_new_plan_id)}>
                      Select a plan...
                    </option>
                    <%= for plan <- @plans do %>
                      <option value={plan.id} selected={@selected_new_plan_id == plan.id}>
                        {plan.name}
                      </option>
                    <% end %>
                  </select>
                  <button
                    type="submit"
                    disabled={is_nil(@selected_new_plan_id)}
                    class="btn btn-primary btn-sm"
                  >
                    Create
                  </button>
                </form>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Usage Stats Card --%>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <h2 class="card-title">Usage Statistics</h2>

            <%= if @limits[:exempt] do %>
              <div class="alert alert-info mt-4">
                <.icon name="lucide-shield-check" class="w-5 h-5" />
                <span>This user is exempt from all limits</span>
              </div>
            <% else %>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
                <.usage_bar
                  label="Storage"
                  current={@usage_stats.storage_used}
                  limit={@limits[:storage_bytes]}
                  format={:bytes}
                />
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Activity Chart --%>
        <.live_component
          module={MagusWeb.Admin.Components.ActivityChartComponent}
          id={"user-activity-#{@user.id}"}
          user_id={@user.id}
          title="Message Activity"
        />
      </div>
    </Layouts.admin>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    class =
      case assigns.status do
        :active -> "badge-success"
        :trialing -> "badge-info"
        :past_due -> "badge-warning"
        :canceled -> "badge-error"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={"badge #{@class}"}>{@status}</span>
    """
  end

  attr :label, :string, required: true
  attr :current, :integer, required: true
  attr :limit, :integer, default: nil
  attr :format, :atom, default: :number

  defp usage_bar(assigns) do
    percentage = calculate_percentage(assigns.current, assigns.limit)
    color = usage_color(percentage)

    assigns =
      assigns
      |> assign(:percentage, percentage)
      |> assign(:color, color)

    ~H"""
    <div>
      <div class="flex justify-between text-sm mb-1">
        <span>{@label}</span>
        <span class="font-medium">
          {format_value(@current, @format)} / {format_limit(@limit, @format)}
        </span>
      </div>
      <div class="w-full bg-base-300 rounded-full h-2.5">
        <div
          class={"h-2.5 rounded-full transition-all duration-300 #{@color}"}
          style={"width: #{@percentage}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp format_period_end(nil), do: "-"

  defp format_period_end(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp calculate_percentage(_current, nil), do: 0
  defp calculate_percentage(_current, 0), do: 0

  defp calculate_percentage(current, limit),
    do: min(100.0, current / limit * 100) |> Float.round(1)

  defp usage_color(percentage) when percentage >= 100, do: "bg-error"
  defp usage_color(percentage) when percentage >= 80, do: "bg-warning"
  defp usage_color(_), do: "bg-success"

  defp format_value(value, :bytes), do: format_bytes(value)
  defp format_value(value, :number), do: value

  defp format_limit(nil, _format), do: "Unlimited"
  defp format_limit(limit, :bytes), do: format_bytes(limit)
  defp format_limit(limit, :number), do: limit

  defp format_bytes(bytes), do: MagusWeb.Formatters.format_bytes(bytes)
end
