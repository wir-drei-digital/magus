defmodule MagusWeb.Admin.ConfigHealthLive do
  @moduledoc """
  Admin configuration health page: a read-only view of `Magus.Config.Health`
  (the same data `mix magus.doctor` reports), grouping required boot config and
  optional capabilities as ok / missing / not-configured.
  """
  use MagusWeb, :live_view

  alias Magus.Config.Health
  alias MagusWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  defp load(socket) do
    checks = Health.checks()

    socket
    |> assign(:page_title, "Configuration")
    |> assign(:current_path, "/admin/config")
    |> assign(:groups, Enum.chunk_by(checks, & &1.category))
    |> assign(:all_required_ok?, Health.all_required_ok?())
  end

  # Read-only diagnostic: re-reads config/env. No mutation, no user input.
  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-8">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">Configuration</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Required configuration and optional capabilities for this instance
              (the same data as <code class="text-xs bg-base-300 px-1 rounded">mix magus.doctor</code>).
            </p>
          </div>
          <button type="button" phx-click="refresh" class="btn btn-outline btn-sm">
            <.icon name="lucide-refresh-cw" class="w-4 h-4" /> Refresh
          </button>
        </div>

        <div
          data-test-required-status={if @all_required_ok?, do: "ok", else: "missing"}
          class={[
            "rounded-lg border px-4 py-3 text-sm flex items-center gap-2",
            @all_required_ok? && "border-success/30 bg-success/10 text-success",
            !@all_required_ok? && "border-error/30 bg-error/10 text-error"
          ]}
        >
          <.icon
            name={if @all_required_ok?, do: "lucide-circle-check", else: "lucide-triangle-alert"}
            class="w-4 h-4 shrink-0"
          />
          <span :if={@all_required_ok?}>All required configuration is present.</span>
          <span :if={!@all_required_ok?}>
            Missing required configuration — see the items marked (required) below.
          </span>
        </div>

        <div :for={group <- @groups} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
            {hd(group).category}
          </h2>
          <div class="card bg-base-200 border border-base-300 overflow-hidden">
            <table class="table table-sm">
              <tbody>
                <tr
                  :for={check <- group}
                  data-test-config-check={check.key}
                  data-test-config-status={check.status}
                  class="hover:bg-base-300/30"
                >
                  <td class="w-24">
                    <.status_badge status={check.status} />
                  </td>
                  <td class="font-medium align-top">
                    {check.label}
                    <span :if={check.required?} class="text-base-content/40 text-xs">
                      (required)
                    </span>
                  </td>
                  <td class="text-base-content/60 text-xs align-top">
                    <span :if={check.status != :ok}>{check.detail}</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", badge_class(@status)]}>{badge_text(@status)}</span>
    """
  end

  defp badge_class(:ok), do: "badge-success"
  defp badge_class(:missing), do: "badge-error"
  defp badge_class(:not_configured), do: "badge-ghost"

  defp badge_text(:ok), do: "ok"
  defp badge_text(:missing), do: "missing"
  defp badge_text(:not_configured), do: "not set"
end
