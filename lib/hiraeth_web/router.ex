defmodule HiraethWeb.Router do
  use HiraethWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HiraethWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :admin_browser do
    plug HiraethWeb.AdminAuth, :require_admin
  end

  pipeline :ops do
    plug :accepts, ["json"]
  end

  scope "/", HiraethWeb do
    pipe_through :ops

    get "/health", HealthController, :health
    get "/ready", HealthController, :ready
  end

  scope "/admin", HiraethWeb do
    pipe_through [:browser]

    get "/session/:token", AdminSessionController, :create
  end

  scope "/admin", HiraethWeb.Admin do
    pipe_through [:browser, :admin_browser]

    live_session :admin, on_mount: [{HiraethWeb.AdminAuth, :require_admin}] do
      live "/", IngestionLive, :index
      live "/ingestion", IngestionLive, :index
      live "/ingestion/providers/:id", IngestionLive, :show
      live "/ingestion/artifacts/:artifact_id", IngestionLive, :artifact
      live "/ingestion/quarantine", QuarantineLive, :index
      live "/ingestion/quarantine/runs/:run_id", QuarantineLive, :run
      live "/ingestion/quarantine/candidates/:candidate_id", QuarantineLive, :candidate
    end

    get "/ingestion/audit/:run_id/export", AuditExportController, :show
  end

  scope "/", HiraethWeb do
    pipe_through :browser

    live "/", HomeLive, :index
    live "/browse", BrowseLive, :index
    live "/search", SearchLive, :index
    live "/contributors", ContributorsLive, :index
    live "/contributors/:slug", ContributorsLive, :show
    live "/publishers", PublishersLive, :index
    live "/publishers/:slug", PublishersLive, :show
    live "/series", SeriesLive, :index
    live "/series/:slug", SeriesLive, :show
    live "/books/:slug", BookLive, :show
    live "/editions/:slug", EditionLive, :show
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:hiraeth, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HiraethWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
