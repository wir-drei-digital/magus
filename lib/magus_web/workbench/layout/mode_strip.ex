defmodule MagusWeb.Workbench.Layout.ModeStrip do
  @moduledoc """
  Leftmost vertical strip of mode icons + bottom utility icons
  (notifications, PAYG usage, help, avatar). All bottom utilities
  open popovers anchored to the right of the strip.
  """
  use MagusWeb, :live_component

  alias MagusWeb.Workbench.Layout.ModePicker

  @impl true
  def render(assigns) do
    ~H"""
    <nav
      class="flex flex-col items-center w-14 bg-wb-bg h-full border-r border-wb-border"
      aria-label="Modes"
    >
      <.link
        navigate={~p"/chat/new"}
        data-mode-logo
        class="mt-3 mb-2 w-10 h-10 flex items-center justify-center text-wb-accent hover:opacity-80 transition-opacity text-[28px] leading-none"
        aria-label="Magus"
        title="Magus"
      >
        ◬
      </.link>

      <div class="flex flex-col items-center gap-1.5 pt-2 flex-1">
        <ModePicker.mode_picker
          current_mode={@current_mode}
          layout={:vertical}
          detail_view_active?={@detail_view_active?}
        />
      </div>

      <div class="flex flex-col items-center gap-1.5 pb-3" data-mode-strip-footer>
        <%!-- Notifications --%>
        <.live_component
          module={MagusWeb.NotificationBellComponent}
          id="notification-bell"
          current_user={@current_user}
          unread_count={@unread_count || 0}
          placement="right-end"
        />

        <%!-- Payment-required: last payment failed, pay-as-you-go usage is paused --%>
        <.payment_required_indicator :if={@usage_data && @usage_data[:delinquent]} />

        <%!-- Pay-as-you-go usage indicator (CHF spent + tokens) --%>
        <.usage_indicator
          :if={@usage_data && !@usage_data.exempt}
          usage_data={@usage_data}
        />

        <%!-- Help / resources --%>
        <.help_dropdown />

        <%!-- User avatar + menu --%>
        <.user_menu_dropdown current_user={@current_user} />
      </div>
    </nav>
    """
  end

  # ============================================================================
  # Payment-required indicator: shown when the subscription is delinquent
  # (last payment failed, pay-as-you-go usage paused). Links to the subscription
  # settings page where the user can re-open the billing portal.
  # ============================================================================

  defp payment_required_indicator(assigns) do
    ~H"""
    <.link
      navigate="/settings/subscription"
      data-billing-state="payment_required"
      class="w-10 h-10 rounded-lg flex items-center justify-center text-error hover:bg-error/10 transition-colors cursor-pointer"
      aria-label={gettext("Payment required: update your payment method")}
      title={gettext("Payment required: update your payment method")}
    >
      <.icon name="lucide-credit-card" class="w-5 h-5" />
    </.link>
    """
  end

  # ============================================================================
  # PAYG usage indicator: opens to the right since the workbench mode strip is on the left edge.
  # ============================================================================

  attr :usage_data, :map, required: true

  defp usage_indicator(assigns) do
    pct = assigns.usage_data.percentage

    {bars, progress_color} =
      cond do
        pct >= 90 -> {[:error, :error, :error], "bg-error"}
        pct >= 75 -> {[:warning, :warning, :warning], "bg-warning"}
        pct >= 40 -> {[:active, :active, :inactive], "bg-success"}
        true -> {[:active, :inactive, :inactive], "bg-success"}
      end

    assigns = assign(assigns, bars: bars, progress_color: progress_color)

    ~H"""
    <.header_dropdown
      placement="right-end"
      panel_class="p-4"
      trigger_class="w-10 h-10 rounded-lg flex items-center justify-center hover:bg-wb-hover transition-colors cursor-pointer"
      aria_label={gettext("Usage this period: %{spent}", spent: format_chf(@usage_data.spent_cents))}
    >
      <:trigger>
        <div class="flex items-center gap-[3px]">
          <div :for={bar <- @bars} class={["w-[5px] h-[14px] rounded-sm", bar_class(bar)]}></div>
        </div>
      </:trigger>
      <:panel>
        <h3 class="text-xs font-semibold text-wb-text-muted uppercase tracking-wider mb-3">
          {gettext("Usage this period")}
        </h3>
        <div class="flex items-center justify-between mb-2">
          <span class="text-sm text-wb-text">{gettext("Spent")}</span>
          <span class="text-sm font-semibold text-wb-text">
            {format_chf(@usage_data.spent_cents)}
          </span>
        </div>
        <div :if={is_integer(@usage_data.cap_cents) and @usage_data.cap_cents > 0}>
          <div class="w-full bg-wb-surface-2 rounded-full h-2.5">
            <div
              class={[@progress_color, "h-2.5 rounded-full transition-all duration-300"]}
              style={"width: #{@usage_data.percentage}%"}
            >
            </div>
          </div>
          <p class="text-xs text-wb-text-muted mt-1">
            <%= if @usage_data[:trial] do %>
              {gettext("of %{cap} free trial allowance", cap: format_chf(@usage_data.cap_cents))}
            <% else %>
              {gettext("of %{cap} monthly cap", cap: format_chf(@usage_data.cap_cents))}
            <% end %>
          </p>
        </div>
        <p :if={@usage_data[:near_cap?]} class="text-xs text-warning mt-2">
          <%= if @usage_data[:trial] do %>
            {gettext(
              "You've used most of your free trial allowance. Subscribe to Pay-as-you-go to keep going."
            )}
          <% else %>
            {gettext(
              "You've used most of your monthly cap. Usage stops at the cap — raise it in Settings if you need more."
            )}
          <% end %>
        </p>
        <div class="flex items-center justify-between mt-3">
          <span class="text-sm text-wb-text">{gettext("Tokens")}</span>
          <span class="text-sm font-semibold text-wb-text">
            {format_tokens(@usage_data.tokens_used)}
          </span>
        </div>
        <a
          href="/settings/subscription"
          class="text-xs text-wb-accent-soft hover:underline mt-3 inline-block"
        >
          {gettext("Manage subscription")}
        </a>
      </:panel>
    </.header_dropdown>
    """
  end

  # Integer cents (CHF) → "CHF 12.34"
  defp format_chf(cents) when is_integer(cents),
    do: "CHF " <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp format_chf(_), do: "CHF 0.00"

  # Token count → compact label ("128.4k" / "512")
  defp format_tokens(n) when is_integer(n) and n >= 1000,
    do: "#{Float.round(n / 1000, 1)}k"

  defp format_tokens(n) when is_integer(n), do: "#{n}"
  defp format_tokens(_), do: "0"

  defp bar_class(:active), do: "bg-success"
  defp bar_class(:warning), do: "bg-warning"
  defp bar_class(:error), do: "bg-error"
  defp bar_class(:inactive), do: "bg-wb-text-dim/30"

  # ============================================================================
  # Help / resources dropdown
  # ============================================================================

  defp help_dropdown(assigns) do
    locale = Gettext.get_locale(MagusWeb.Gettext) || "en"
    assigns = assign(assigns, :locale, locale)

    ~H"""
    <.header_dropdown
      placement="right-end"
      width_class="w-56"
      panel_class="p-1"
      trigger_class="w-10 h-10 rounded-lg flex items-center justify-center hover:bg-wb-hover text-wb-text-muted transition-colors cursor-pointer"
      aria_label={gettext("Resources")}
    >
      <:trigger>
        <.icon name="lucide-help-circle" class="w-5 h-5" />
      </:trigger>
      <:panel>
        <ul>
          <.help_item
            href={"/#{@locale}/docs"}
            icon="lucide-book-open"
            label={gettext("Documentation")}
          />
          <.help_item
            href={"/#{@locale}/help"}
            icon="lucide-help-circle"
            label={gettext("Help & FAQ")}
          />
          <.help_item href={"/#{@locale}/blog"} icon="lucide-newspaper" label={gettext("Blog")} />
          <.help_item
            href={"/#{@locale}/support"}
            icon="lucide-message-circle"
            label={gettext("Contact Support")}
          />
          <.help_item
            href="https://discord.gg/6EfPDhmWRb"
            icon="lucide-message-square"
            label={gettext("Discord Community")}
            external
          />
        </ul>
      </:panel>
    </.header_dropdown>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :external, :boolean, default: false

  defp help_item(assigns) do
    ~H"""
    <li>
      <a
        href={@href}
        target={if @external, do: "_blank", else: nil}
        class="flex items-center gap-2 px-3 py-2 text-sm text-wb-text-secondary hover:text-wb-text hover:bg-wb-hover rounded-md transition-colors"
      >
        <.icon name={@icon} class="w-4 h-4" />
        <span class="flex-1">{@label}</span>
        <.icon :if={@external} name="lucide-external-link" class="w-3 h-3 text-wb-text-dim" />
      </a>
    </li>
    """
  end

  # ============================================================================
  # User avatar + menu
  # ============================================================================

  attr :current_user, :map, required: true

  defp user_menu_dropdown(assigns) do
    ~H"""
    <.header_dropdown
      placement="right-end"
      width_class="w-56"
      panel_class="p-1"
      trigger_class="w-10 h-10 rounded-lg flex items-center justify-center hover:bg-wb-hover transition-colors cursor-pointer"
      aria_label={gettext("Account menu")}
    >
      <:trigger>
        <.user_avatar user={@current_user} size="sm" />
      </:trigger>
      <:panel>
        <div class="px-3 py-2 border-b border-wb-border mb-1">
          <p class="text-sm font-medium text-wb-text truncate">{@current_user.email}</p>
          <p class="text-xs text-wb-text-muted">{gettext("Signed in")}</p>
        </div>
        <ul>
          <.menu_link href="/jobs" icon="lucide-clock" label={gettext("Scheduled Jobs")} />
          <.menu_link href="/settings" icon="lucide-settings" label={gettext("Settings")} />
          <.menu_link
            href="/settings/subscription"
            icon="lucide-credit-card"
            label={gettext("Subscription")}
          />
          <.menu_link
            :if={@current_user.is_admin}
            href="/admin"
            icon="lucide-shield-check"
            label={gettext("Admin")}
          />
        </ul>
        <div class="px-3 py-2 border-t border-wb-border mt-1 flex items-center justify-between gap-2">
          <span class="text-xs text-wb-text-muted">{gettext("Theme")}</span>
          <.theme_picker />
        </div>
        <div class="px-3 py-2 border-t border-wb-border mt-1">
          <a
            href="/sign-out"
            class="flex items-center gap-2 px-2 py-1.5 text-sm text-error hover:bg-error/10 rounded-md transition-colors"
          >
            <.icon name="lucide-log-out" class="w-4 h-4" />
            <span>{gettext("Sign out")}</span>
          </a>
        </div>
      </:panel>
    </.header_dropdown>
    """
  end

  # Compact 3-option theme picker (system / light / dark). Uses wb-* tokens
  # so the active state remains visible inside the workbench, where the shared
  # Layouts.theme_toggle's bg-base-100 indicator collapses against bg-base-300.
  defp theme_picker(assigns) do
    ~H"""
    <div class="inline-flex items-center rounded-full border border-wb-border bg-wb-surface-2 p-0.5 gap-0.5">
      <.theme_picker_button theme="system" icon="lucide-monitor" label={gettext("System")} />
      <.theme_picker_button theme="light" icon="lucide-sun" label={gettext("Light")} />
      <.theme_picker_button theme="dark" icon="lucide-moon" label={gettext("Dark")} />
    </div>
    """
  end

  attr :theme, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp theme_picker_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={JS.dispatch("phx:set-theme")}
      data-phx-theme={@theme}
      aria-label={@label}
      class={
        [
          "w-7 h-7 rounded-full flex items-center justify-center cursor-pointer transition-colors",
          # Active state via parent's data-theme. System has no data-theme on <html>.
          case @theme do
            "system" ->
              "[:root:not([data-theme])_&]:bg-wb-hover [:root:not([data-theme])_&]:text-wb-text text-wb-text-muted hover:text-wb-text"

            "light" ->
              "[[data-theme=light]_&]:bg-wb-hover [[data-theme=light]_&]:text-wb-text text-wb-text-muted hover:text-wb-text"

            "dark" ->
              "[[data-theme=dark]_&]:bg-wb-hover [[data-theme=dark]_&]:text-wb-text text-wb-text-muted hover:text-wb-text"
          end
        ]
      }
    >
      <.icon name={@icon} class="w-3.5 h-3.5" />
    </button>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp menu_link(assigns) do
    ~H"""
    <li>
      <a
        href={@href}
        class="flex items-center gap-2 px-3 py-2 text-sm text-wb-text-secondary hover:text-wb-text hover:bg-wb-hover rounded-md transition-colors"
      >
        <.icon name={@icon} class="w-4 h-4" />
        <span>{@label}</span>
      </a>
    </li>
    """
  end
end
