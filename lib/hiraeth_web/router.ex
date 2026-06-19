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

  pipeline :api do
    plug :accepts, ["json"]
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
