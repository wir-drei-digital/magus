defmodule MagusWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use MagusWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the main navigation items.
  """
  def nav_items do
    [
      %{label: gettext("Chat"), href: "/chat", icon: "lucide-messages-square"},
      %{label: gettext("Agents"), href: "/agents", icon: "lucide-bot"},
      %{label: gettext("Prompts"), href: "/prompts", icon: "lucide-book-open"},
      %{label: gettext("Models"), href: "/models", icon: "lucide-cpu"}
    ]
  end

  @doc """
  Marketing header with pill-style navigation for content pages.
  Logo left, centered pill nav, CTA right.
  """
  attr :current_user, :map, default: nil
  attr :locale, :string, default: "en"
  attr :content_locale, :string, default: "en"

  def marketing_header(assigns) do
    ~H"""
    <header class="fixed top-0 left-0 right-0 z-40">
      <div class="flex h-16 items-center justify-between px-6 lg:px-8 max-w-7xl mx-auto">
        <%!-- Logo --%>
        <a href={"/#{@content_locale}/"} class="flex items-end gap-2 font-semibold">
          <span class="text-primary text-3xl leading-none">◬</span>
          <span class="text-base-content font-logo">MAGUS</span>
        </a>

        <%!-- Centered pill nav --%>
        <nav class="hidden md:flex items-center gap-1 bg-base-200/60 border border-base-300/50 rounded-full px-2 py-1 backdrop-blur-sm">
          <a
            href={"/#{@content_locale}/#features"}
            class="px-4 py-1.5 text-sm font-medium text-base-content/60 hover:text-base-content rounded-full transition-colors"
          >
            {dgettext("content", "Features")}
          </a>
          <a
            href={"/#{@content_locale}/#pricing"}
            class="px-4 py-1.5 text-sm font-medium text-base-content/60 hover:text-base-content rounded-full transition-colors"
          >
            {dgettext("content", "Pricing")}
          </a>
          <a
            href={"/#{@content_locale}/blog"}
            class="px-4 py-1.5 text-sm font-medium text-base-content/60 hover:text-base-content rounded-full transition-colors"
          >
            {dgettext("content", "Blog")}
          </a>
          <a
            href="/models"
            class="px-4 py-1.5 text-sm font-medium text-base-content/60 hover:text-base-content rounded-full transition-colors"
          >
            {dgettext("content", "Models")}
          </a>
          <a
            href="/prompts"
            class="px-4 py-1.5 text-sm font-medium text-base-content/60 hover:text-base-content rounded-full transition-colors"
          >
            {dgettext("content", "Prompts")}
          </a>
          <a
            href="https://discord.gg/6EfPDhmWRb"
            target="_blank"
            class="px-4 py-1.5 text-sm font-medium text-base-content/60 hover:text-base-content rounded-full transition-colors"
          >
            {dgettext("content", "Community")}
          </a>
        </nav>

        <%!-- Right CTA + mobile menu --%>
        <div class="flex items-center gap-3">
          <%= if @current_user do %>
            <a href="/chat" class="btn btn-primary btn-sm rounded-full px-5">
              {dgettext("content", "Chat")}
            </a>
          <% else %>
            <a href="/sign-in" class="btn btn-primary btn-sm rounded-full px-5">
              {dgettext("content", "Get Started")}
            </a>
          <% end %>

          <%!-- Mobile menu button --%>
          <button
            class="md:hidden p-2 hover:bg-base-300 rounded-lg"
            phx-click={Phoenix.LiveView.JS.toggle(to: "#marketing-mobile-menu")}
          >
            <.icon name="lucide-menu" class="w-5 h-5" />
          </button>
        </div>
      </div>

      <%!-- Mobile nav --%>
      <nav
        id="marketing-mobile-menu"
        class="hidden md:hidden border-t border-base-300 px-4 py-3 bg-base-100/95 backdrop-blur-sm"
      >
        <a
          href="#features"
          class="block px-3 py-2 text-sm font-medium text-base-content/70 hover:text-base-content rounded-lg"
        >
          {dgettext("content", "Features")}
        </a>
        <a
          href="#pricing"
          class="block px-3 py-2 text-sm font-medium text-base-content/70 hover:text-base-content rounded-lg"
        >
          {dgettext("content", "Pricing")}
        </a>
        <a
          href={"/#{@content_locale}/blog"}
          class="block px-3 py-2 text-sm font-medium text-base-content/70 hover:text-base-content rounded-lg"
        >
          {dgettext("content", "Blog")}
        </a>
        <a
          href={"/#{@content_locale}/help"}
          class="block px-3 py-2 text-sm font-medium text-base-content/70 hover:text-base-content rounded-lg"
        >
          {dgettext("content", "Help")}
        </a>
        <a
          href="https://discord.gg/6EfPDhmWRb"
          target="_blank"
          class="block px-3 py-2 text-sm font-medium text-base-content/70 hover:text-base-content rounded-lg"
        >
          {dgettext("content", "Community")}
        </a>
      </nav>
    </header>
    """
  end

  @doc """
  Marketing layout for the landing/home page.

  Uses the marketing_header instead of the app header.
  No sidebar, no search bar, no app-level user menu.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil, doc: "the current authenticated user"
  attr :locale, :string, default: "en", doc: "the locale"
  attr :bg_class, :string, default: "bg-base-100", doc: "background class for root container"
  slot :inner_block, required: true

  def marketing(assigns) do
    content_locale =
      assigns[:locale] || (assigns[:current_user] && to_string(assigns.current_user.language)) ||
        Gettext.get_locale(MagusWeb.Gettext) || "en"

    assigns = assign(assigns, content_locale: content_locale)

    ~H"""
    <div class={["min-h-screen flex flex-col", @bg_class]}>
      <.marketing_header
        current_user={@current_user}
        locale={@locale}
        content_locale={@content_locale}
      />

      <main class="flex-1 min-w-0">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_user, :map, default: nil, doc: "the current authenticated user"
  attr :page_title, :string, default: nil, doc: "the page title"
  attr :show_sidebar, :boolean, default: true, doc: "whether to show the sidebar"
  attr :sidebar_width, :string, default: "w-64", doc: "width class for sidebar"
  attr :locale, :string, default: nil, doc: "current locale for home link"
  attr :bg_class, :string, default: "bg-base-100", doc: "background class for root container"

  attr :hide_mobile_menu, :boolean,
    default: false,
    doc: "hide the mobile menu button (for pages with custom mobile handling)"

  attr :overlay_header, :boolean,
    default: false,
    doc: "let content render behind the header (no top padding, transparent header)"

  slot :inner_block, required: true
  slot :notification_bell
  slot :sidebar, doc: "optional sidebar content"

  def app(assigns) do
    # Determine home link based on user language or passed locale
    home_link =
      cond do
        assigns[:current_user] && assigns.current_user.language ->
          "/#{assigns.current_user.language}/"

        assigns[:locale] ->
          "/#{assigns.locale}/"

        true ->
          "/"
      end

    content_locale =
      assigns[:locale] || (assigns[:current_user] && to_string(assigns.current_user.language)) ||
        Gettext.get_locale(MagusWeb.Gettext) || "en"

    {unread_count, notifications} = load_notifications(assigns)

    assigns =
      assign(assigns,
        home_link: home_link,
        content_locale: content_locale,
        unread_count: unread_count,
        notifications: notifications
      )

    ~H"""
    <div class={["min-h-screen flex flex-col", @bg_class]}>
      <%!-- Header --%>
      <header class={[
        if(@hide_mobile_menu, do: "md:fixed", else: "fixed"),
        "top-0 left-0 right-0 z-40",
        "header-blur"
      ]}>
        <div class="flex h-14 items-center px-4 lg:px-6">
          <%!-- Logo --%>
          <a href={@home_link} class="flex items-end gap-2 font-semibold mr-6">
            <span class="text-primary text-3xl leading-none">◬</span>
            <span class="text-base-content font-logo">MAGUS</span>
          </a>

          <%!-- Main Nav --%>
          <nav class="hidden md:flex items-center gap-1">
            <a
              :for={item <- nav_items()}
              href={item.href}
              class="px-3 py-2 text-sm font-medium text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-lg transition-colors"
            >
              {item.label}
            </a>
          </nav>

          <%!-- Centered Search input --%>
          <%= if @current_user do %>
            <form action="/search" method="get" class="hidden sm:flex flex-1 justify-center px-4">
              <div class="relative w-full max-w-md">
                <.icon
                  name="lucide-search"
                  class="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-base-content/40"
                />
                <input
                  type="text"
                  name="q"
                  placeholder={gettext("Search messages, conversations, files...")}
                  class="w-full pl-9 pr-3 py-1.5 text-sm bg-base-200 border border-base-300 rounded-lg text-base-content placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary transition-colors"
                />
              </div>
            </form>
          <% end %>

          <%!-- Right side actions --%>
          <div class="flex items-center gap-3 ml-auto">
            <%!-- User menu or sign in --%>
            <%= if @current_user do %>
              <%= if @notification_bell do %>
                {render_slot(@notification_bell)}
              <% else %>
                <.static_notification_bell
                  unread_count={@unread_count}
                  notifications={@notifications}
                />
              <% end %>
              <.resources_dropdown />
              <.user_menu current_user={@current_user} />
            <% else %>
              <.theme_toggle />
              <a href="/sign-in" class="btn btn-primary btn-sm">
                {gettext("Sign in")}
              </a>
            <% end %>
          </div>

          <%!-- Mobile menu button --%>
          <button
            :if={!@hide_mobile_menu}
            class="md:hidden ml-2 p-2 hover:bg-base-300 rounded-lg"
            phx-click={JS.toggle(to: "#mobile-menu")}
          >
            <.icon name="lucide-menu" class="w-5 h-5" />
          </button>
        </div>

        <%!-- Mobile nav --%>
        <nav
          :if={!@hide_mobile_menu}
          id="mobile-menu"
          class="hidden md:hidden border-t border-base-300 px-4 py-3"
        >
          <a
            :for={item <- nav_items()}
            href={item.href}
            class="flex items-center gap-3 px-3 py-2 text-sm font-medium text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-lg"
          >
            <.icon name={item.icon} class="w-5 h-5" />
            {item.label}
          </a>
          <div class="border-t border-base-300 mt-2 pt-2">
            <span class="px-3 text-xs text-base-content/40 uppercase tracking-wider">
              {gettext("Resources")}
            </span>
            <a
              :for={
                {label, icon, href} <- [
                  {gettext("Help & FAQ"), "lucide-help-circle", "/#{@content_locale}/help"},
                  {gettext("Blog"), "lucide-newspaper", "/#{@content_locale}/blog"},
                  {gettext("Contact Support"), "lucide-message-circle",
                   "/#{@content_locale}/support"},
                  {gettext("Privacy Policy"), "lucide-shield", "/#{@content_locale}/privacy"},
                  {gettext("Terms of Service"), "lucide-file-text", "/#{@content_locale}/terms"},
                  {gettext("Impressum"), "lucide-building", "/#{@content_locale}/impressum"}
                ]
              }
              href={href}
              class="flex items-center gap-3 px-3 py-2 text-sm font-medium text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-lg"
            >
              <.icon name={icon} class="w-5 h-5" />
              {label}
            </a>
            <a
              href="https://discord.gg/6EfPDhmWRb"
              target="_blank"
              class="flex items-center gap-3 px-3 py-2 text-sm font-medium text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-lg"
            >
              <.icon name="lucide-message-square" class="w-5 h-5" />
              {gettext("Discord Community")}
              <.icon name="lucide-external-link" class="w-3 h-3 text-base-content/30" />
            </a>
          </div>
        </nav>
      </header>

      <%!-- Main content area --%>
      <div class={[
        "flex flex-1",
        if(@overlay_header, do: "", else: if(@hide_mobile_menu, do: "md:pt-14", else: "pt-14"))
      ]}>
        <%!-- Optional Sidebar --%>
        <%= if @show_sidebar && @sidebar != [] do %>
          <aside class={"hidden lg:block flex-shrink-0 border-r border-base-300 bg-base-200/50 #{@sidebar_width}"}>
            <div class="sticky top-14 h-[calc(100vh-3.5rem)] overflow-y-auto p-4">
              {render_slot(@sidebar)}
            </div>
          </aside>
        <% end %>

        <%!-- Page content --%>
        <main class="flex-1 min-w-0">
          {render_slot(@inner_block)}
        </main>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Renders the resources dropdown in the header.
  """
  def resources_dropdown(assigns) do
    content_locale = assigns[:locale] || Gettext.get_locale(MagusWeb.Gettext) || "en"
    assigns = assign(assigns, :content_locale, content_locale)

    ~H"""
    <div class="dropdown dropdown-end">
      <button
        tabindex="0"
        class="flex items-center justify-center w-9 h-9 rounded-lg hover:bg-base-300 transition-colors cursor-pointer"
        aria-label={gettext("Resources")}
      >
        <.icon name="lucide-help-circle" class="w-4 h-4 text-base-content/70" />
      </button>
      <ul
        tabindex="0"
        class="dropdown-content z-50 mt-2 w-56 bg-base-200 border border-base-300 rounded-lg shadow-lg p-1"
      >
        <li>
          <a
            href={"/#{@content_locale}/docs"}
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
          >
            <.icon name="lucide-book-open" class="w-4 h-4" /> {gettext("Documentation")}
          </a>
        </li>
        <li>
          <a
            href={"/#{@content_locale}/help"}
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
          >
            <.icon name="lucide-help-circle" class="w-4 h-4" /> {gettext("Help & FAQ")}
          </a>
        </li>
        <li>
          <a
            href={"/#{@content_locale}/blog"}
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
          >
            <.icon name="lucide-newspaper" class="w-4 h-4" /> {gettext("Blog")}
          </a>
        </li>
        <li>
          <a
            href={"/#{@content_locale}/support"}
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
          >
            <.icon name="lucide-message-circle" class="w-4 h-4" /> {gettext("Contact Support")}
          </a>
        </li>
        <li>
          <a
            href="https://discord.gg/6EfPDhmWRb"
            target="_blank"
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
          >
            <.icon name="lucide-message-square" class="w-4 h-4" />
            {gettext("Discord Community")}
            <.icon name="lucide-external-link" class="w-3 h-3 ml-auto text-base-content/30" />
          </a>
        </li>
        <%!-- <li class="border-t border-base-300 mt-1 pt-1">
          <a
            href={"/#{@content_locale}/privacy"}
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
          >
            <.icon name="lucide-shield" class="w-4 h-4" /> {gettext("Privacy Policy")}
          </a>
        </li>
        <li>
          <a
            href={"/#{@content_locale}/terms"}
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
          >
            <.icon name="lucide-file-text" class="w-4 h-4" /> {gettext("Terms of Service")}
          </a>
        </li>
        <li>
          <a
            href={"/#{@content_locale}/impressum"}
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
          >
            <.icon name="lucide-building" class="w-4 h-4" /> {gettext("Impressum")}
          </a>
        </li> --%>
      </ul>
    </div>
    """
  end

  @doc """
  Renders user menu dropdown.
  """
  attr :current_user, :map, required: true

  def user_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <button
        tabindex="0"
        class="flex items-center gap-2 p-1.5 hover:bg-base-300 rounded-lg transition-colors"
      >
        <.user_avatar user={@current_user} size="sm" />
        <.icon name="lucide-chevron-down" class="w-4 h-4 text-base-content/50 hidden sm:block" />
      </button>
      <ul
        tabindex="0"
        class="dropdown-content z-50 mt-2 w-56 bg-base-200 border border-base-300 rounded-lg shadow-lg p-1"
      >
        <li class="px-3 py-2 border-b border-base-300 mb-1">
          <p class="text-sm font-medium text-base-content truncate">{@current_user.email}</p>
          <p class="text-xs text-base-content/50">{gettext("Signed in")}</p>
        </li>
        <li>
          <a
            href="/jobs"
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
          >
            <.icon name="lucide-clock" class="w-4 h-4" /> {gettext("Scheduled Jobs")}
          </a>
        </li>
        <li>
          <a
            href="/settings"
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
          >
            <.icon name="lucide-settings" class="w-4 h-4" /> {gettext("Settings")}
          </a>
        </li>
        <li>
          <a
            href="/settings/subscription"
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
          >
            <.icon name="lucide-credit-card" class="w-4 h-4" /> {gettext("Subscription")}
          </a>
        </li>
        <%= if @current_user.is_admin do %>
          <li>
            <a
              href="/admin"
              class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-md"
            >
              <.icon name="lucide-shield-check" class="w-4 h-4" /> {gettext("Admin")}
            </a>
          </li>
        <% end %>
        <li class="px-3 py-2 border-t border-base-300 mt-1">
          <div class="flex items-center justify-between">
            <span class="text-sm text-base-content/70">{gettext("Theme")}</span>
            <.theme_toggle />
          </div>
        </li>
        <li>
          <a
            href="/sign-out"
            class="flex items-center gap-2 px-3 py-2 text-sm text-error hover:bg-error/10 rounded-md"
          >
            <.icon name="lucide-log-out" class="w-4 h-4" /> {gettext("Sign out")}
          </a>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Renders a content page layout with header, flexible content area, and footer.

  The content area uses `flex: 1` so the footer stays at the bottom of the viewport
  even when content is short, and scrolls naturally when content is long.

  Used by public content pages: blog, help, privacy, terms, impressum, support.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil, doc: "the current authenticated user"
  attr :locale, :string, default: nil, doc: "current locale"
  attr :base_path, :string, default: "/", doc: "current page path for language switcher"
  slot :inner_block, required: true

  def content(assigns) do
    ~H"""
    <.marketing
      flash={@flash}
      current_user={@current_user}
      locale={@locale}
      bg_class="bg-spectral"
    >
      <div class="pt-16 flex flex-col" style="min-height: calc(100vh - 4rem)">
        <div class="flex-1">
          {render_slot(@inner_block)}
        </div>
        <.site_footer locale={@locale} base_path={@base_path} />
      </div>
    </.marketing>
    """
  end

  @doc """
  Renders a full-width layout without the standard header.
  Useful for pages like chat that manage their own chrome.
  """
  attr :flash, :map, required: true
  slot :inner_block, required: true

  def bare(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      {render_slot(@inner_block)}
    </div>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <div
        id="connection-status"
        phx-hook="ConnectionStatus"
        class="fixed top-0 inset-x-0 z-50 hidden"
        aria-live="assertive"
      >
        <div
          data-stage="subtle"
          role="status"
          class="flex items-center justify-center gap-2 bg-base-300 text-base-content/70 text-xs py-1"
        >
          <.icon name="lucide-refresh-cw" class="size-3 motion-safe:animate-spin" />
          {gettext("Reconnecting...")}
        </div>
        <div
          data-stage="escalated"
          role="alert"
          class="hidden flex items-center justify-center gap-2 bg-error text-error-content text-xs py-1"
        >
          {gettext("The server is unreachable at the moment, please try again later")}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the admin navigation items.
  """
  def admin_nav_items do
    [
      %{label: gettext("Dashboard"), href: "/admin", icon: "lucide-bar-chart-2"},
      %{label: gettext("Users"), href: "/admin/users", icon: "lucide-users"},
      %{label: gettext("Models"), href: "/admin/models", icon: "lucide-cpu"},
      %{label: gettext("Plans"), href: "/admin/plans", icon: "lucide-credit-card"},
      %{label: gettext("Announcements"), href: "/admin/announcements", icon: "lucide-megaphone"},
      %{label: gettext("Usage"), href: "/admin/usage", icon: "lucide-activity"},
      %{label: gettext("Providers"), href: "/admin/providers", icon: "lucide-server"},
      %{label: gettext("Configuration"), href: "/admin/config", icon: "lucide-heart-pulse"},
      %{label: gettext("Telemetry"), href: "/admin/telemetry", icon: "lucide-gauge"}
    ]
  end

  @doc """
  Renders the admin layout with fixed sidebar.

  ## Examples

      <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
        <h1>Admin Content</h1>
      </Layouts.admin>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, required: true, doc: "the current authenticated user"
  attr :current_path, :string, default: "/admin", doc: "the current path for active state"

  slot :inner_block, required: true

  def admin(assigns) do
    ~H"""
    <div class="min-h-screen max-h-screen bg-base-100 flex overflow-hidden">
      <%!-- Sidebar --%>
      <aside class="hidden lg:flex flex-col w-64 border-r border-base-300 bg-base-200/50">
        <%!-- Logo/Brand --%>
        <div class="flex items-center gap-2 h-14 px-4 border-b border-base-300">
          <a href="/" class="flex items-end gap-2 font-semibold">
            <span class="text-primary text-3xl leading-none">◬</span>
            <span class="text-base-content font-logo">MAGUS</span>
          </a>
        </div>

        <%!-- Navigation --%>
        <nav class="flex-1 overflow-y-auto p-4">
          <ul class="space-y-1">
            <li :for={item <- admin_nav_items()}>
              <.link
                navigate={item.href}
                class={[
                  "flex items-center gap-3 px-3 py-2 text-sm font-medium rounded-lg transition-colors",
                  if(active_path?(@current_path, item.href),
                    do: "bg-primary/10 text-primary",
                    else: "text-base-content/70 hover:text-base-content hover:bg-base-300/50"
                  )
                ]}
              >
                <.icon name={item.icon} class="w-5 h-5" />
                {item.label}
              </.link>
            </li>
          </ul>
        </nav>

        <%!-- Back to App Link --%>
        <div class="p-4 border-t border-base-300">
          <a
            href="/chat"
            class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-lg transition-colors"
          >
            <.icon name="lucide-arrow-left" class="w-4 h-4" />
            {gettext("Back to App")}
          </a>
        </div>
      </aside>

      <%!-- Main Content Area --%>
      <div class="flex-1 flex flex-col min-w-0">
        <%!-- Top Header --%>
        <header class="flex items-center h-14 px-4 lg:px-6 border-b border-base-300 bg-base-100">
          <%!-- Mobile menu button --%>
          <button
            class="lg:hidden p-2 hover:bg-base-300 rounded-lg mr-2"
            phx-click={JS.toggle(to: "#admin-mobile-menu")}
          >
            <.icon name="lucide-menu" class="w-5 h-5" />
          </button>

          <%!-- Breadcrumb / Title area --%>
          <div class="flex-1">
            <h1 class="text-lg font-semibold text-base-content">{gettext("Admin Dashboard")}</h1>
          </div>

          <%!-- Right side actions --%>
          <div class="flex items-center gap-3">
            <.theme_toggle />
            <.user_menu current_user={@current_user} />
          </div>
        </header>

        <%!-- Mobile Sidebar --%>
        <div
          id="admin-mobile-menu"
          class="hidden lg:hidden fixed inset-0 z-50 bg-base-100/80 backdrop-blur-sm"
          phx-click={JS.hide(to: "#admin-mobile-menu")}
        >
          <aside
            class="w-64 h-full bg-base-200 border-r border-base-300 shadow-xl"
            phx-click="stop-propagation"
          >
            <div class="flex items-center justify-between h-14 px-4 border-b border-base-300">
              <span class="font-semibold text-base-content">{gettext("Admin Menu")}</span>
              <button
                class="p-1 hover:bg-base-300 rounded"
                phx-click={JS.hide(to: "#admin-mobile-menu")}
              >
                <.icon name="lucide-x" class="w-5 h-5" />
              </button>
            </div>
            <nav class="p-4">
              <ul class="space-y-1">
                <li :for={item <- admin_nav_items()}>
                  <.link
                    navigate={item.href}
                    class={[
                      "flex items-center gap-3 px-3 py-2 text-sm font-medium rounded-lg transition-colors",
                      if(active_path?(@current_path, item.href),
                        do: "bg-primary/10 text-primary",
                        else: "text-base-content/70 hover:text-base-content hover:bg-base-300/50"
                      )
                    ]}
                  >
                    <.icon name={item.icon} class="w-5 h-5" />
                    {item.label}
                  </.link>
                </li>
              </ul>
            </nav>
            <div class="p-4 border-t border-base-300">
              <a
                href="/chat"
                class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/70 hover:text-base-content hover:bg-base-300/50 rounded-lg"
              >
                <.icon name="lucide-arrow-left" class="w-4 h-4" />
                {gettext("Back to App")}
              </a>
            </div>
          </aside>
        </div>

        <%!-- Page Content --%>
        <main class="flex-1 overflow-y-auto p-4 lg:p-6">
          <div class="max-w-7xl mx-auto">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :unread_count, :integer, required: true
  attr :notifications, :list, required: true

  defp static_notification_bell(assigns) do
    grouped =
      assigns.notifications
      |> Enum.group_by(fn n -> n.target_conversation_id || :no_conversation end)
      |> Enum.sort_by(fn {_k, group} -> hd(group).inserted_at end, {:desc, DateTime})

    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <.header_dropdown
      aria_label={
        ngettext(
          "1 unread notification",
          "%{count} unread notifications",
          @unread_count
        )
      }
      width_class="w-80"
      panel_class="max-h-96 overflow-y-auto"
    >
      <:trigger>
        <.icon name="lucide-bell" class="w-4 h-4 text-base-content/70" />
        <span
          :if={@unread_count > 0}
          class="absolute -top-0.5 -right-0.5 flex items-center justify-center min-w-[18px] h-[18px] px-1 text-[10px] font-bold text-primary-content bg-primary rounded-full"
        >
          {if @unread_count > 99, do: "99+", else: @unread_count}
        </span>
      </:trigger>
      <:panel>
        <.notification_panel notifications={@notifications} grouped={@grouped} />
      </:panel>
    </.header_dropdown>
    """
  end

  attr :notifications, :list, required: true
  attr :grouped, :list, required: true

  defp notification_panel(assigns) do
    ~H"""
    <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
      {gettext("Notifications")}
    </h3>

    <%= if @notifications == [] do %>
      <div class="px-4 py-8 text-center">
        <.icon name="lucide-bell-off" class="w-8 h-8 text-base-content/30 mx-auto mb-2" />
        <p class="text-sm text-base-content/50">{gettext("No unread notifications")}</p>
      </div>
    <% else %>
      <ul class="divide-y divide-base-300">
        <%= for {_conv_id, group} <- @grouped do %>
          <% primary = hd(group) %>
          <% count = length(group) %>
          <li class="hover:bg-base-200/50 transition-colors">
            <a
              href={notification_href(primary)}
              class="px-4 py-3 flex items-start gap-3"
            >
              <.notification_icon_badge type={primary.notification_type} />
              <.notification_item_content notification={primary} count={count} />
            </a>
          </li>
        <% end %>
      </ul>
    <% end %>
    """
  end

  defp notification_href(%{target_conversation_id: id}) when not is_nil(id),
    do: "/chat/#{id}"

  defp notification_href(_), do: "/chat"

  attr :type, :atom, required: true

  defp notification_icon_badge(assigns) do
    ~H"""
    <div class={"flex-shrink-0 mt-0.5 w-7 h-7 rounded-full flex items-center justify-center #{notification_icon_bg(@type)}"}>
      <.icon name={notification_icon_name(@type)} class="w-3.5 h-3.5" />
    </div>
    """
  end

  attr :notification, :map, required: true
  attr :count, :integer, required: true

  defp notification_item_content(assigns) do
    ~H"""
    <div class="flex-1 min-w-0">
      <p class="text-sm font-medium text-base-content truncate">
        {@notification.title || notification_title(@notification.notification_type)}
      </p>
      <p :if={@notification.body} class="text-xs text-base-content/60 truncate">
        {@notification.body}
      </p>
      <div class="flex items-center gap-2 mt-1">
        <span class="text-xs text-base-content/40">
          {format_relative_time(@notification.inserted_at)}
        </span>
        <span :if={@count > 1} class="text-xs text-primary font-medium">
          +{@count - 1}
        </span>
      </div>
    </div>
    """
  end

  defp notification_title(:task_update), do: gettext("Task Update")
  defp notification_title(:task_completed), do: gettext("Task Completed")
  defp notification_title(:mention), do: gettext("Mention")
  defp notification_title(:message), do: gettext("New Response")
  defp notification_title(:system), do: gettext("System Notification")
  defp notification_title(_), do: gettext("Notification")

  defp notification_icon_name(:task_update), do: "lucide-refresh-cw"
  defp notification_icon_name(:task_completed), do: "lucide-check-circle"
  defp notification_icon_name(:mention), do: "lucide-at-sign"
  defp notification_icon_name(_), do: "lucide-bell"

  defp notification_icon_bg(:task_update), do: "bg-info/20 text-info"
  defp notification_icon_bg(:task_completed), do: "bg-success/20 text-success"
  defp notification_icon_bg(:mention), do: "bg-warning/20 text-warning"
  defp notification_icon_bg(_), do: "bg-base-300 text-base-content/50"

  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{n}m ago", n: div(diff, 60))
      diff < 86400 -> gettext("%{n}h ago", n: div(diff, 3600))
      true -> gettext("%{n}d ago", n: div(diff, 86400))
    end
  end

  defp load_notifications(assigns) do
    # If the LiveView hook already set unread_count, use that and load notifications.
    # Otherwise (dead views), fetch both from the database.
    user = assigns[:current_user]
    has_live_count = Map.has_key?(assigns, :unread_count) and assigns.unread_count > 0

    cond do
      is_nil(user) ->
        {0, []}

      has_live_count ->
        notifications =
          case Magus.Notifications.list_unread_notifications(actor: user) do
            {:ok, list} -> list
            _ -> []
          end

        {assigns.unread_count, notifications}

      true ->
        notifications =
          case Magus.Notifications.list_unread_notifications(actor: user) do
            {:ok, list} -> list
            _ -> []
          end

        {length(notifications), notifications}
    end
  end

  defp active_path?(current_path, href) do
    # Exact match for dashboard, prefix match for other routes
    if href == "/admin" do
      current_path == "/admin" or current_path == "/admin/dashboard"
    else
      String.starts_with?(current_path, href)
    end
  end

  @doc """
  Renders the site-wide footer with Resources, Legal, and Language columns.

  Used on the landing page and all public content pages (privacy, terms, etc.).
  """
  attr :locale, :string, default: nil

  attr :base_path, :string,
    default: "/",
    doc: "current page path without locale prefix for language switcher"

  def site_footer(assigns) do
    locale = assigns[:locale] || Gettext.get_locale(MagusWeb.Gettext)
    assigns = assign(assigns, :locale, locale)

    ~H"""
    <footer class="border-t border-base-300 py-8 px-6">
      <div class="max-w-4xl mx-auto">
        <div class="flex flex-col md:flex-row justify-between gap-8 mb-6">
          <div class="flex flex-col gap-2">
            <span class="text-xs text-base-content/40 uppercase tracking-wider font-semibold">
              {gettext("Resources")}
            </span>
            <a
              href={"/#{@locale}/docs"}
              class="text-sm text-base-content/60 hover:text-base-content transition-colors"
            >
              {gettext("Documentation")}
            </a>
            <a
              href={"/#{@locale}/help"}
              class="text-sm text-base-content/60 hover:text-base-content transition-colors"
            >
              {gettext("Help & FAQ")}
            </a>
            <a
              href={"/#{@locale}/blog"}
              class="text-sm text-base-content/60 hover:text-base-content transition-colors"
            >
              {gettext("Blog")}
            </a>
            <a
              href={"/#{@locale}/support"}
              class="text-sm text-base-content/60 hover:text-base-content transition-colors"
            >
              {gettext("Contact Support")}
            </a>
            <a
              href="https://discord.gg/6EfPDhmWRb"
              target="_blank"
              class="text-sm text-base-content/60 hover:text-base-content transition-colors inline-flex items-center gap-1"
            >
              {gettext("Discord Community")}
              <.icon name="lucide-external-link" class="w-3 h-3" />
            </a>
          </div>
          <div class="flex flex-col gap-2">
            <span class="text-xs text-base-content/40 uppercase tracking-wider font-semibold">
              {gettext("Legal")}
            </span>
            <a
              href={"/#{@locale}/privacy"}
              class="text-sm text-base-content/60 hover:text-base-content transition-colors"
            >
              {gettext("Privacy Policy")}
            </a>
            <a
              href={"/#{@locale}/terms"}
              class="text-sm text-base-content/60 hover:text-base-content transition-colors"
            >
              {gettext("Terms of Service")}
            </a>
            <a
              href={"/#{@locale}/impressum"}
              class="text-sm text-base-content/60 hover:text-base-content transition-colors"
            >
              {gettext("Impressum")}
            </a>
          </div>
          <div class="flex flex-col gap-2">
            <span class="text-xs text-base-content/40 uppercase tracking-wider font-semibold">
              {gettext("Language")}
            </span>
            <div class="flex items-center gap-1 bg-base-200 rounded-lg p-1 w-fit">
              <a
                href={"/en#{@base_path}"}
                class={"px-2 py-1 rounded text-xs font-medium transition-colors #{if @locale == "en", do: "bg-primary text-primary-content", else: "hover:bg-base-300"}"}
              >
                EN
              </a>
              <a
                href={"/de#{@base_path}"}
                class={"px-2 py-1 rounded text-xs font-medium transition-colors #{if @locale == "de", do: "bg-primary text-primary-content", else: "hover:bg-base-300"}"}
              >
                DE
              </a>
            </div>
          </div>
        </div>
        <div class="border-t border-base-300 pt-4 flex items-center justify-center gap-2 text-sm text-base-content/50">
          <span>{gettext("Built with")}</span>
          <.icon name="lucide-heart" class="w-5 h-5 hover:bg-red-500" />
          <span>{gettext("by")}</span>
          <a
            href="https://wirdrei.digital"
            target="_blank"
            class="text-primary hover:underline"
          >
            wirdrei.digital
          </a>
        </div>
      </div>
    </footer>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="lucide-monitor" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="lucide-sun" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="lucide-moon" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
