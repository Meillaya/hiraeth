import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/hiraeth start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") == "true" do
  config :hiraeth, HiraethWeb.Endpoint, server: true
end

config :hiraeth, HiraethWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :hiraeth, :scrapling_sidecar,
  base_url: System.get_env("SCRAPLING_SIDECAR_URL") || "http://localhost:8000"

# Autonomous ingestion kill-switch: HIRAETH_SCHEDULED_INGEST=false drops ALL
# autonomous cron entries (scheduler tick, weekly cover refresh, weekly
# provenance audit) so autonomy is fully off; manual mix tasks are unaffected.
# Queues and the Pruner always stay.
scheduled_ingest = System.get_env("HIRAETH_SCHEDULED_INGEST", "true") != "false"

oban_plugins =
  [
    Oban.Plugins.Pruner
  ] ++
    if scheduled_ingest do
      [
        {Oban.Plugins.Cron,
         crontab: [
           {"*/15 * * * *", Hiraeth.Oban.ProviderSchedulerWorker},
           {"0 4 * * 0", Hiraeth.Oban.CoverRefreshWorker},
           {"30 4 * * 0", Hiraeth.Oban.ProvenanceAuditWorker}
         ]}
      ]
    else
      []
    end

config :hiraeth, Oban, plugins: oban_plugins

if config_env() == :prod do
  scrapling_sidecar_url =
    System.get_env("SCRAPLING_SIDECAR_URL") ||
      raise """
      environment variable SCRAPLING_SIDECAR_URL is missing.
      For example: http://sidecar:8000
      """

  config :hiraeth, :scrapling_sidecar, base_url: scrapling_sidecar_url

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :hiraeth, Hiraeth.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      For example: example.com
      """

  live_view_signing_salt =
    System.get_env("LIVE_VIEW_SIGNING_SALT") ||
      raise """
      environment variable LIVE_VIEW_SIGNING_SALT is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :hiraeth, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :hiraeth, HiraethWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network access only.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base,
    live_view: [signing_salt: live_view_signing_salt]

  log_level =
    case System.get_env("LOG_LEVEL") do
      nil ->
        :info

      level when level in ~w(debug info warning error) ->
        String.to_atom(level)

      other ->
        raise "invalid LOG_LEVEL #{inspect(other)}; expected one of: debug, info, warning, error"
    end

  Logger.configure(level: log_level)

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :hiraeth, HiraethWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :hiraeth, HiraethWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
