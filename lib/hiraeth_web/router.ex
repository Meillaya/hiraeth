defmodule HiraethWeb.Router do
  use HiraethWeb, :router
  use AshAuthentication.Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HiraethWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HiraethWeb do
    pipe_through :browser

    auth_routes AuthController, Hiraeth.Accounts.User, path: "/auth"
    sign_out_route AuthController

    sign_in_route(
      auth_routes_prefix: "/auth",
      on_mount: [{HiraethWeb.LiveUserAuth, :live_no_user}]
    )

    ash_authentication_live_session :public,
      on_mount: [{HiraethWeb.LiveUserAuth, :live_user_optional}] do
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

    ash_authentication_live_session :admin_required,
      on_mount: {HiraethWeb.LiveUserAuth, :live_admin_required} do
      live "/admin", Admin.DashboardLive, :index
      live "/admin/editions", Admin.EditionsLive, :index
      live "/admin/review", Admin.ReviewLive, :index
      live "/admin/review/:id", Admin.ReviewLive, :show
      live "/admin/imports", Admin.ImportsLive, :index
      live "/admin/imports/new", Admin.ImportsLive, :new
      live "/admin/imports/:id", Admin.ImportsLive, :show
      live "/admin/publishers", Admin.CatalogLive, :publishers
      live "/admin/imprints", Admin.CatalogLive, :imprints
      live "/admin/works", Admin.CatalogLive, :works
      live "/admin/contributors", Admin.CatalogLive, :contributors
      live "/admin/series", Admin.CatalogLive, :series
      live "/admin/identifiers", Admin.CatalogLive, :identifiers
      live "/admin/covers", Admin.CoversLive, :index
      live "/admin/curation-overrides", Admin.CatalogLive, :curation_overrides

      if Mix.env() == :test do
        live "/admin/__actor_probe", Admin.ActorProbeLive, :index
      end
    end
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
