defmodule ResidencyScheduleWeb.Router do
  use ResidencyScheduleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ResidencyScheduleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug ResidencyScheduleWeb.Plugs.RequireAuth
  end

  pipeline :admin_authenticated do
    plug ResidencyScheduleWeb.Plugs.RequireAdmin
  end

  pipeline :mcp do
    plug :accepts, ["json"]
    plug ResidencyScheduleWeb.Plugs.RequireBearerToken
  end

  # ── OAuth 2.1 + MCP ───────────────────────────────────────────────────────

  scope "/", ResidencyScheduleWeb do
    pipe_through :api

    get "/.well-known/oauth-authorization-server", OAuthController, :authorization_server_metadata
    get "/.well-known/oauth-protected-resource", OAuthController, :protected_resource_metadata
    get "/.well-known/oauth-protected-resource/mcp", OAuthController, :protected_resource_metadata
    post "/oauth/register", OAuthController, :register
    post "/oauth/token", OAuthController, :token
  end

  scope "/oauth", ResidencyScheduleWeb do
    pipe_through :browser

    get "/authorize", OAuthController, :authorize
    post "/authorize", OAuthController, :decide
  end

  scope "/mcp", ResidencyScheduleWeb do
    pipe_through :mcp

    post "/", MCPController, :create
    get "/", MCPController, :not_allowed
    delete "/", MCPController, :not_allowed
  end

  # ── Public auth routes ────────────────────────────────────────────────────

  scope "/", ResidencyScheduleWeb do
    pipe_through :browser
    get "/login", AuthController, :show
    post "/login/identify", AuthController, :identify
    post "/login/send-link", AuthController, :send_magic_link
    post "/login/password", AuthController, :password_login
    get "/auth/verify", AuthController, :verify
    post "/auth/verify", AuthController, :confirm
    post "/auth/set-password", AuthController, :set_initial_password
    post "/logout", AuthController, :delete
    get "/feed/:token/calendar.ics", IcalController, :feed
  end

  # ── Authenticated site routes ─────────────────────────────────────────────
  #
  # One live_session for every signed-in page, admin pages included, so the
  # nav moves between them without a page load and the sticky chat widget in
  # the :site layout keeps its conversation across the trip. The plugs guard
  # only the first request; `:ensure_authenticated` re-checks on every live
  # navigation, and each admin LiveView adds `:ensure_admin` itself.

  scope "/", ResidencyScheduleWeb do
    live_session :authenticated,
      on_mount: [{ResidencyScheduleWeb.UserAuth, :ensure_authenticated}],
      layout: {ResidencyScheduleWeb.Layouts, :site} do
      scope "/" do
        pipe_through [:browser, :authenticated]

        live "/", CalendarLive.Index, :index
        live "/schedule", ScheduleLive.Index, :index
        live "/residents/:id", ResidentLive.Show, :show
        live "/calendar", CalendarLive.Index, :index
        live "/compare", CompareLive.Index, :index
        live "/activities", ActivitiesLive.Index, :index
      end

      scope "/admin" do
        pipe_through [:browser, :admin_authenticated]

        live "/", AdminLive.Index, :index
        live "/denied", AdminLive.Denied, :index
        live "/upload", UploadLive.Index, :index
        live "/build", BuilderLive.Index, :index
        live "/edit", EditLive.Index, :index
      end
    end

    scope "/" do
      pipe_through [:browser, :authenticated]

      get "/residents/:id/calendar.ics", IcalController, :show
      post "/set-home/:resident_id", AuthController, :set_home
      post "/unset-home", AuthController, :unset_home
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:residency_schedule, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ResidencyScheduleWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
