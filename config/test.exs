import Config

config :hiraeth,
       :token_signing_secret,
       System.get_env("TOKEN_SIGNING_SECRET") ||
         "dev-test-token-signing-secret-change-before-production"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :hiraeth, Hiraeth.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "54320")),
  database: "hiraeth_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hiraeth, HiraethWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "zWrpIkwXpXnhEg+Zm1k12PSI9XaeVdkayFO7R+2rULygXQdwU/jrJMe/EW5k2HJY",
  server: false

# In test we don't send emails
config :hiraeth, Hiraeth.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
