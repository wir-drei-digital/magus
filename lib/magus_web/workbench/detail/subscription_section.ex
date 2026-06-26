defmodule MagusWeb.Workbench.Detail.SubscriptionSection do
  @moduledoc """
  Seam for the "Subscription" settings section rendered inside
  `MagusWeb.Workbench.Detail.SettingsView`.

  The subscription UI is a billing-edition concern: its implementation
  (`MagusWeb.SettingsLive.SubscriptionLive`) compile-references `Magus.Billing`
  and Stripe. Because `SettingsView` is part of the always-loaded workbench, a
  direct reference would drag `Magus.Billing` into a pure-OSS build. This module
  resolves the section provider at runtime via

      config :magus, MagusWeb.Workbench.Detail.SubscriptionSection,
        impl: MagusWeb.SettingsLive.SubscriptionLive

  so the combined/cloud app gets the full billing section while a pure-OSS build
  with no impl configured falls back to `Default` (a neutral placeholder).

  Like the sibling `UsageSection`, the provider is a function provider, not a
  routed LiveView: `SettingsView` calls `init_assigns/2`, `render_section/1`,
  and `handle_event/3`.
  """

  @type socket :: Phoenix.LiveView.Socket.t()
  @type assigns :: map()

  @doc """
  Loads the section's assigns onto the socket. `{:error, reason}` signals the
  section is unavailable for this user (e.g. no subscription record), which
  `SettingsView` surfaces as an inline notice.
  """
  @callback init_assigns(socket, user :: struct() | map()) :: {:ok, socket} | {:error, term()}

  @doc "Renders the section body."
  @callback render_section(assigns) :: Phoenix.LiveView.Rendered.t()

  @doc "Handles a section-owned LiveView event."
  @callback handle_event(event :: binary(), params :: map(), socket) :: {:noreply, socket}

  @doc false
  def impl, do: Application.get_env(:magus, __MODULE__, [])[:impl] || __MODULE__.Default

  @doc false
  def init_assigns(socket, user), do: impl().init_assigns(socket, user)

  @doc false
  def render_section(assigns), do: impl().render_section(assigns)

  @doc false
  def handle_event(event, params, socket), do: impl().handle_event(event, params, socket)

  defmodule Default do
    @moduledoc """
    OSS fallback for the subscription section: no billing backend, so the
    section renders a neutral notice and ignores events.
    """
    use MagusWeb, :html

    @behaviour MagusWeb.Workbench.Detail.SubscriptionSection

    @impl true
    def init_assigns(socket, _user), do: {:ok, socket}

    @impl true
    def render_section(assigns) do
      ~H"""
      <p class="text-base-content/70">
        {gettext("Subscription management is not available on this instance.")}
      </p>
      """
    end

    @impl true
    def handle_event(_event, _params, socket), do: {:noreply, socket}
  end
end
