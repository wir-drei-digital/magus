defmodule MagusWeb.CoreRouter do
  @moduledoc """
  Core pipelines and routes for the open-core / cloud composition seam.

  A router composes the core surface by doing:

      defmodule MagusWeb.Router do
        use MagusWeb, :router
        use MagusWeb.CoreRouter

        core_pipelines()
        core_routes()
      end

  `magus_cloud`'s router does the same and then adds its own pipelines and
  scopes (Stripe, checkout/portal, marketing/CMS, billing admin) after the
  core calls. `use MagusWeb.CoreRouter` brings in the AshAuthentication / Oban
  router imports and the shared plug functions that core pipelines (and
  `pipe_through`) reference, so the seam needs only the two macro calls.

  This is a pure refactor of the original inline router; the Phase 4 repo split
  carves the cloud-bound scopes (Stripe, content, checkout) out of `core_routes/0`
  into `magus_cloud`.
  """

  defmacro __using__(_opts) do
    quote do
      import Oban.Web.Router
      use AshAuthentication.Phoenix.Router
      import AshAuthentication.Plug.Helpers
      import MagusWeb.CoreRouter, only: [core_pipelines: 0, core_routes: 0]

      # Shared plug functions referenced by core pipelines and by `pipe_through`.
      # Phoenix `pipe_through` can call any 2-arity plug in the router module,
      # not only `pipeline` blocks (e.g. `:require_authenticated_user_browser`),
      # so these must live in the router that composes the core routes.

      # Plug to require authenticated user for API routes
      defp require_authenticated_user(conn, _opts) do
        if conn.assigns[:current_user] do
          conn
        else
          conn
          |> put_status(:unauthorized)
          |> Phoenix.Controller.json(%{error: "Authentication required"})
          |> halt()
        end
      end

      # Plug to capture invite_token from params into session for post-auth acceptance
      defp capture_invite_token(conn, _opts) do
        case conn.params["invite_token"] do
          token when is_binary(token) and token != "" ->
            Plug.Conn.put_session(conn, :invite_token, token)

          _ ->
            conn
        end
      end

      # Plug to require authenticated user for browser routes
      defp require_authenticated_user_browser(conn, _opts) do
        if conn.assigns[:current_user] do
          conn
        else
          conn
          |> Phoenix.Controller.put_flash(:error, "You must be logged in to access this page.")
          |> Phoenix.Controller.redirect(to: "/sign-in")
          |> halt()
        end
      end

      defp require_admin_user(conn, _opts) do
        user = conn.assigns[:current_user]

        if user && user.is_admin do
          conn
        else
          conn
          |> put_status(:not_found)
          |> Phoenix.Controller.put_view(MagusWeb.ErrorHTML)
          |> Phoenix.Controller.render("404.html")
          |> halt()
        end
      end
    end
  end

  @doc """
  Core HTTP pipelines (browser, rpc, api, file serving, webhook, ...).

  Invoke inside a router module that has already done `use MagusWeb, :router`
  and `use MagusWeb.CoreRouter`.
  """
  defmacro core_pipelines do
    quote do
      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
        plug :fetch_live_flash
        plug :put_root_layout, html: {MagusWeb.Layouts, :root}
        plug :protect_from_forgery
        plug :put_secure_browser_headers
        plug :sign_in_with_remember_me
        plug :load_from_session
        plug :capture_invite_token
        plug MagusWeb.Plugs.SetLocale
        plug MagusWeb.Plugs.NextUiSwitch
      end

      # AshTypescript RPC for the SvelteKit workbench (frontend/). Same-origin,
      # session-authenticated; no CSRF token. The actual cross-site barrier is the
      # SameSite=Lax session cookie: browsers won't attach it to cross-site POSTs
      # (and a JSON GET response body is unreadable cross-origin under SOP). Note
      # CORS does NOT stop the request from reaching us — it only blocks response
      # reads — so if the SPA ever moves off this origin or the cookie's SameSite
      # attribute changes, this pipeline needs a CSRF token or bearer auth.
      pipeline :rpc do
        plug :accepts, ["json"]
        plug :fetch_session
        plug :sign_in_with_remember_me
        plug :load_from_session
        plug :set_actor, :user
        plug :require_authenticated_user
      end

      pipeline :api do
        plug :accepts, ["json"]
        plug :load_from_bearer
        plug :set_actor, :user
      end

      # API routes requiring browser session authentication
      pipeline :authenticated_api do
        plug :accepts, ["json"]
        plug :fetch_session
        plug :load_from_session
      end

      # API v1 routes with API key authentication
      pipeline :api_v1 do
        plug :accepts, ["json"]
        plug MagusWeb.Api.Plugs.ApiAuthPlug
      end

      # API v2 routes with token-based auth (Brain API)
      pipeline :api_v2 do
        plug :accepts, ["json"]
        plug MagusWeb.Api.Plugs.ApiTokenAuthPlug
        plug MagusWeb.Api.Plugs.RequireTokenScope
      end

      # Browser routes requiring authenticated user
      pipeline :require_auth_browser do
        plug :require_authenticated_user_browser
      end

      # File serving pipeline - session + auth without format restrictions
      # Used for serving binary files (images, videos, PDFs, etc.) where
      # the browser pipeline's :accepts ["html"] would reject the request.
      # Auth is optional: FileController handles access control per-file,
      # falling back to share-link-based access for shared conversations.
      pipeline :file_serving do
        plug :fetch_session
        plug :put_secure_browser_headers
        plug :sign_in_with_remember_me
        plug :load_from_session
      end

      # Sandbox preview proxy — like :file_serving but with flash support for
      # the auth redirect. No :accepts restriction (proxies JS, CSS, images, etc.)
      # and no CSRF protection (proxied apps may POST).
      pipeline :sandbox_proxy do
        plug :fetch_session
        plug :fetch_live_flash
        plug :put_secure_browser_headers
        plug :sign_in_with_remember_me
        plug :load_from_session
        plug :require_authenticated_user_browser
      end

      # Browser routes requiring admin user
      pipeline :require_admin do
        plug :require_admin_user
      end

      # Webhook pipeline with raw body parser for signature verification
      pipeline :webhook do
        plug Plug.Parsers,
          parsers: [MagusWeb.Plugs.RawBodyParser],
          pass: ["*/*"]
      end
    end
  end

  @doc """
  Core routes/scopes. Invoke after `core_pipelines/0` in the composing router.
  """
  defmacro core_routes do
    quote do
      # AshTypescript RPC endpoints for the SvelteKit workbench
      scope "/rpc", MagusWeb.Rpc do
        pipe_through :rpc

        post "/run", RpcController, :run
        post "/validate", RpcController, :validate
        get "/socket-token", RpcController, :socket_token
        post "/knowledge/oauth-finalize", RpcController, :knowledge_oauth_finalize
        post "/upload", UploadController, :create
        post "/profile-image/upload", ImageController, :upload
        post "/profile-image/generate", ImageController, :generate
        post "/profile-image/remove", ImageController, :remove
        get "/api-tokens", ApiTokenController, :index
        post "/api-tokens", ApiTokenController, :create
        delete "/api-tokens/:id", ApiTokenController, :delete
        get "/mcp/registry", McpRegistryController, :index
        post "/mcp/registry/import", McpRegistryController, :import
        post "/mcp/servers/:id/connect", McpRegistryController, :connect
        get "/account/deletion-preflight", AccountController, :deletion_preflight
        post "/account/delete", AccountController, :delete
        get "/search", SearchController, :search
      end

      # The SPA is served at the site root (see the catch-all in each composing
      # router). Its assets live under /_app and are handled by Plug.Static.

      # Authenticated file serving (replaces Plug.Static for uploads)
      scope "/uploads/files", MagusWeb do
        pipe_through [:file_serving]

        get "/*path", FileController, :serve
      end

      scope "/", MagusWeb do
        pipe_through [:file_serving]

        get "/files/:id/download", FileController, :download
      end

      # Legacy routes — redirect to workbench equivalents with URL query params
      scope "/", MagusWeb do
        pipe_through [:browser, :require_authenticated_user_browser]

        get "/agents/:id/edit", RedirectController, :agent_edit
        get "/agents/:id/edit/:section", RedirectController, :agent_edit_section
        get "/prompts/:id/edit", RedirectController, :prompt_edit
      end

      scope "/", MagusWeb do
        pipe_through :browser

        # The authenticated workbench (classic LiveView) is retired: the SPA now
        # owns /chat, /brain, /agents, /files, /settings, /jobs, /search,
        # /history, /workspaces, and /prompts via the root catch-all. The classic
        # modules remain under lib/magus_web/legacy/ for reference. The public
        # entry points below (catalogs, invite + share links) are NOT the
        # workbench and stay routed.

        # /prompts and /prompts/:id are now owned by the SPA (the root catch-all);
        # the classic PromptsLive/PromptDetailLive stay in lib/ for reference.

        # Public models routes
        ash_authentication_live_session :public_models,
          on_mount: [{MagusWeb.LiveUserAuth, :live_user_optional}] do
          live "/models", ModelsLive, :index
          live "/models/:id", ModelsLive, :show
        end

        # Join conversation via invite link (optional auth - will prompt to sign in)
        ash_authentication_live_session :join_conversation,
          on_mount: [{MagusWeb.LiveUserAuth, :live_user_optional}] do
          # Public invite link (anyone with link can join if conversation is public)
          live "/chat/join/:token", JoinConversationLive, :public_link
          # Email invitation (only the invited email can join)
          live "/chat/invite/:token", JoinConversationLive, :email_invite
        end

        # Workspace invite acceptance (optional auth - handles both logged-in and new users)
        ash_authentication_live_session :workspace_invites,
          on_mount: [{MagusWeb.LiveUserAuth, :live_user_optional}] do
          live "/workspaces/invite/:token", WorkspaceLive.AcceptInvite, :accept
        end

        # Shared conversation (read-only view)
        ash_authentication_live_session :shared_conversations,
          on_mount: [{MagusWeb.LiveUserAuth, :live_user_optional}] do
          live "/shared/:token", SharedConversationLive, :show
        end
      end

      # Sandbox service preview (authenticated reverse proxy)
      # Uses :sandbox_proxy instead of :browser to avoid :accepts ["html"] rejection
      # for non-HTML resources (JS, CSS, images, etc.) and CSRF protection which
      # would block POST/PUT requests from the proxied application.
      scope "/sandbox", MagusWeb do
        pipe_through [:sandbox_proxy]

        match :*, "/preview/:conversation_id/*path", SandboxPreviewController, :proxy
      end

      scope "/api/json" do
        pipe_through [:api]

        forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
          path: "/api/json/open_api",
          default_model_expand_depth: 4

        forward "/", MagusWeb.AshJsonApiRouter
      end

      # Public health/liveness probe (Fly.io health checks, ops dashboards).
      # No authentication: must be reachable from anywhere.
      scope "/", MagusWeb do
        pipe_through [:api]

        get "/health", HealthController, :index
      end

      scope "/", MagusWeb do
        pipe_through :browser

        # Vanity redirect for the magus CLI installer
        get "/install.sh", Content.InstallScriptController, :show

        # NOTE: the root route `/` is intentionally NOT defined here. It is owned
        # by the composing router (`MagusWeb.Router` serves the workbench;
        # `magus_cloud`'s router serves a marketing landing) so editions can pick
        # their own root without a duplicate-route conflict against this macro.

        auth_routes AuthController, Magus.Accounts.User, path: "/auth"
        sign_out_route AuthController

        # Email change confirmation
        get "/settings/confirm-email/:token", SettingsController, :confirm_email_change

        # Custom sign-in and magic link confirmation LiveViews
        # (replaces built-in sign_in_route and magic_sign_in_route macros)

        # Remove this if you do not want to use the reset password feature
        reset_route auth_routes_prefix: "/auth",
                    overrides: [
                      MagusWeb.AuthOverrides,
                      Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                    ]

        # Remove this if you do not use the confirmation strategy
        confirm_route Magus.Accounts.User, :confirm_new_user,
          auth_routes_prefix: "/auth",
          overrides: [MagusWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI]
      end

      # My Data settings: data export + account deletion controller endpoints
      scope "/", MagusWeb do
        pipe_through [:browser, :require_auth_browser]

        get "/settings/data/export", SettingsController, :export_data
        post "/settings/data/delete", SettingsController, :delete_account
      end

      # Custom sign-in, magic link confirmation, and registration (onboarding flow)
      scope "/", MagusWeb do
        pipe_through :browser

        ash_authentication_live_session :onboarding,
          on_mount: [{MagusWeb.LiveUserAuth, :live_no_user}] do
          live "/sign-in", OnboardingLive.SignInLive, :sign_in
          live "/magic_link/:token", OnboardingLive.MagicLinkConfirmLive, :magic_link_confirm
          live "/register", OnboardingLive.RegisterLive, :register
        end
      end

      # Password reset request form (built-in SignInLive with :reset action)
      # Separate scope without MagusWeb alias to avoid module prefixing
      scope "/" do
        pipe_through :browser

        ash_authentication_live_session :password_reset_request,
          on_mount: [{MagusWeb.LiveUserAuth, :live_no_user}],
          session:
            {AshAuthentication.Phoenix.Router, :generate_session,
             [
               %{
                 "overrides" => [
                   MagusWeb.AuthOverrides,
                   AshAuthentication.Phoenix.Overrides.DaisyUI
                 ],
                 "auth_routes_prefix" => "/auth"
               }
             ]} do
          live "/reset", AshAuthentication.Phoenix.SignInLive, :reset
        end
      end

      # Complete profile (authenticated, but no profile completion check to avoid redirect loop)
      scope "/", MagusWeb do
        pipe_through :browser

        ash_authentication_live_session :complete_profile,
          on_mount: [{MagusWeb.LiveUserAuth, :live_user_required_no_profile_check}] do
          live "/complete-profile", OnboardingLive.CompleteProfileLive, :complete_profile
        end
      end

      # CLI authorization callback flow for `magus login`
      scope "/cli", MagusWeb do
        pipe_through [:browser, :require_auth_browser]

        ash_authentication_live_session :cli_authorize do
          live "/authorize", Cli.CliAuthorizeLive, :authorize
        end
      end

      # Other scopes may use custom stacks.
      # scope "/api", MagusWeb do
      #   pipe_through :api
      # end

      # Integration webhooks (Telegram, Discord, Slack, etc.)
      # Each provider has its own verification mechanism
      scope "/webhooks", MagusWeb do
        pipe_through [:webhook]

        post "/:provider/:integration_id", WebhookController, :webhook
      end

      # API v1 routes with token authentication
      scope "/api/v1", MagusWeb.Api do
        pipe_through [:api_v1]

        post "/messages", MessageController, :create
      end

      # Brain API v2 (token-authenticated REST)
      scope "/api/v2", MagusWeb.Api.V2 do
        pipe_through [:api_v2]

        resources "/brains", BrainsController, only: [:index, :create, :show, :update, :delete]

        get "/brains/:brain_id/pages", PagesController, :index
        post "/brains/:brain_id/pages", PagesController, :create
        get "/brains/:brain_id/pages/:slug", PagesController, :show_by_slug

        post "/brains/:brain_id/search", SearchController, :search

        resources "/pages", PagesController, only: [:show, :update, :delete]

        get "/pages", PagesController, :index_by_tag
        post "/pages/:id/clear", PagesController, :clear
        post "/pages/:id/undo", PagesController, :undo

        get "/sources/:id", SourcesController, :show

        get "/brains/:brain_id/tags", TagsController, :index
      end

      # OAuth routes for integration providers (requires authenticated user)
      scope "/oauth", MagusWeb do
        pipe_through [:browser, :require_auth_browser]

        get "/:provider/authorize", OAuthController, :authorize
        get "/:provider/callback", OAuthController, :callback

        # Per-user MCP server OAuth 2.1 (Magus is the MCP client). The literal
        # `mcp/` + 3 path segments does not collide with the 2-segment
        # `/:provider/authorize|callback` routes above.
        get "/mcp/:server_id/start", MCP.OAuthController, :start
        get "/mcp/:server_id/callback", MCP.OAuthController, :callback
      end

      # Admin routes (requires admin user)
      scope "/admin", MagusWeb do
        pipe_through :browser

        ash_authentication_live_session :admin_routes,
          on_mount: [
            {MagusWeb.LiveUserAuth, :live_admin_required}
          ] do
          live "/", Admin.DashboardLive, :index
          live "/dashboard", Admin.DashboardLive, :index
          live "/users", Admin.UsersLive, :index
          live "/users/:id", Admin.UserDetailLive, :show
          live "/models", Admin.ModelsLive, :index
          live "/models/new", Admin.ModelsLive, :new
          live "/models/from-registry", Admin.ModelsLive, :from_registry
          live "/models/roles", Admin.ModelRolesLive, :index
          live "/models/:id/edit", Admin.ModelsLive, :edit
          live "/plans", Admin.PlansLive, :index
          live "/plans/new", Admin.PlansLive, :new
          live "/plans/:id/edit", Admin.PlansLive, :edit
          live "/announcements", Admin.AnnouncementsLive, :index
          live "/announcements/new", Admin.AnnouncementsLive, :new
          live "/announcements/:id/edit", Admin.AnnouncementsLive, :edit
          live "/providers", Admin.ProvidersLive, :index
          live "/providers/new", Admin.ProvidersLive, :new
          live "/providers/:id/edit", Admin.ProvidersLive, :edit
          live "/config", Admin.ConfigHealthLive, :index
          live "/usage", Admin.UsageLive, :index
          live "/workspaces", Admin.WorkspacesLive, :index
          live "/workspaces/:id/edit", Admin.WorkspacesLive, :edit
        end
      end

      # LiveDashboard within admin (requires admin user)
      scope "/admin" do
        pipe_through [:browser, :require_admin]

        import Phoenix.LiveDashboard.Router

        live_dashboard "/telemetry",
          metrics: MagusWeb.Telemetry,
          live_session_name: :admin_live_dashboard
      end

      # Enable LiveDashboard and Swoosh mailbox preview in development
      if Application.compile_env(:magus, :dev_routes) do
        # If you want to use the LiveDashboard in production, you should put
        # it behind authentication and allow only admins to access it.
        # If your application does not have an admins-only section yet,
        # you can use Plug.BasicAuth to set up some basic authentication
        # as long as you are also using SSL (which you should anyway).
        import Phoenix.LiveDashboard.Router

        scope "/dev" do
          pipe_through :browser

          live_dashboard "/dashboard", metrics: MagusWeb.Telemetry
          forward "/mailbox", Plug.Swoosh.MailboxPreview
        end

        scope "/" do
          pipe_through :browser

          oban_dashboard("/oban")
        end
      end
    end
  end
end
