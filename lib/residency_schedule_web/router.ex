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
    plug ResidencyScheduleWeb.Plugs.RequireAuthOrAdmin
  end

  pipeline :admin_authenticated do
    plug ResidencyScheduleWeb.Plugs.RequireAdmin
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

  # ── Admin auth routes (unauthenticated) ──────────────────────────────────

  scope "/admin", ResidencyScheduleWeb do
    pipe_through :browser
    get "/login", AuthController, :admin_show
    post "/login", AuthController, :admin_create
    post "/logout", AuthController, :admin_delete
  end

  # ── Authenticated site routes ─────────────────────────────────────────────

  scope "/", ResidencyScheduleWeb do
    pipe_through [:browser, :authenticated]
    live "/", ScheduleLive.Index, :index
    live "/residents/:id", ResidentLive.Show, :show
    live "/calendar", CalendarLive.Index, :index
    live "/compare", CompareLive.Index, :index
    get "/residents/:id/calendar.ics", IcalController, :show
    post "/set-home/:resident_id", AuthController, :set_home
    post "/unset-home", AuthController, :unset_home
  end

  # ── Admin-only routes ─────────────────────────────────────────────────────

  scope "/admin", ResidencyScheduleWeb do
    pipe_through [:browser, :admin_authenticated]
    live "/", AdminLive.Index, :index
    live "/upload", UploadLive.Index, :index
    live "/build", BuilderLive.Index, :index
    live "/edit", EditLive.Index, :index
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
