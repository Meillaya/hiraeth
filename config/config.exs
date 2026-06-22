# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :hiraeth,
  ecto_repos: [Hiraeth.Repo],
  generators: [timestamp_type: :utc_datetime]

config :hiraeth, :ash_domains, [
  Hiraeth.Catalog,
  Hiraeth.Sources,
  Hiraeth.Covers,
  Hiraeth.Imports,
  Hiraeth.Search,
  Hiraeth.Audit
]

# Configure the endpoint
config :hiraeth, HiraethWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HiraethWeb.ErrorHTML, json: HiraethWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Hiraeth.PubSub,
  live_view: [signing_salt: "Ww+/bY7D"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :hiraeth, Hiraeth.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  hiraeth: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  hiraeth: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :hiraeth, Oban,
  repo: Hiraeth.Repo,
  queues: [ingestion: 4, covers: 4, audit: 2],
  plugins: [Oban.Plugins.Pruner]

config :hiraeth, :scrapling_sidecar, base_url: "http://localhost:8000"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
