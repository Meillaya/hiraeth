defmodule Hiraeth.ObanConfigKillSwitchTest do
  @moduledoc """
  Runtime kill-switch contract for autonomous ingestion.

  `config/runtime.exs` reads `HIRAETH_SCHEDULED_INGEST` (default "true").
  When "false", the Oban config drops ALL autonomous cron entries (the
  15-minute scheduler tick, the weekly cover refresh, and the weekly
  provenance audit): autonomy fully off, manual mix tasks unaffected.
  Queues and the Pruner always stay.

  Verified with `Config.Reader` against `env: :prod` so the release-boot
  path is the one under test, plus the devenv dev-guard pin.
  """

  use ExUnit.Case, async: false

  @repo_root Path.expand("../..", __DIR__)
  @runtime_config_path Path.join(@repo_root, "config/runtime.exs")

  @required_prod_env %{
    "SCRAPLING_SIDECAR_URL" => "http://sidecar:8000",
    "DATABASE_URL" => "postgres://hiraeth:secret@localhost/hiraeth_prod",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "PHX_HOST" => "hiraeth.example.com",
    "LIVE_VIEW_SIGNING_SALT" => "0123456789abcdef0123456789abcdef",
    "LOG_LEVEL" => "warning"
  }

  setup do
    # The prod block of config/runtime.exs raises unless these are present;
    # LOG_LEVEL=warning keeps the logger at the test-env level.
    original_scheduled_ingest = System.get_env("HIRAETH_SCHEDULED_INGEST")

    for {name, value} <- @required_prod_env do
      System.put_env(name, value)
    end

    on_exit(fn ->
      for name <- Map.keys(@required_prod_env) do
        System.delete_env(name)
      end

      # Restore, never delete: the devenv shell exports the dev guard value
      # and later modules in the same VM read it for their own branches.
      case original_scheduled_ingest do
        nil -> System.delete_env("HIRAETH_SCHEDULED_INGEST")
        value -> System.put_env("HIRAETH_SCHEDULED_INGEST", value)
      end
    end)

    :ok
  end

  describe "HIRAETH_SCHEDULED_INGEST kill-switch" do
    test "false drops every autonomous cron entry; Pruner and queues stay" do
      System.put_env("HIRAETH_SCHEDULED_INGEST", "false")

      plugins = read_oban_plugins()

      assert Oban.Plugins.Pruner in plugins,
             "the Pruner must stay regardless of the kill-switch"

      refute Enum.any?(plugins, &match?({Oban.Plugins.Cron, _}, &1)),
             "kill-switch false must remove the Cron plugin entirely"
    end

    test "unset defaults to true: all three autonomous cron entries present" do
      System.delete_env("HIRAETH_SCHEDULED_INGEST")

      crontab = read_crontab()

      assert length(crontab) == 3

      assert {"*/15 * * * *", Hiraeth.Oban.ProviderSchedulerWorker} in crontab
      assert {"0 4 * * 0", Hiraeth.Oban.CoverRefreshWorker} in crontab
      assert {"30 4 * * 0", Hiraeth.Oban.ProvenanceAuditWorker} in crontab
    end

    test "explicit true keeps all three autonomous cron entries" do
      System.put_env("HIRAETH_SCHEDULED_INGEST", "true")

      crontab = read_crontab()

      assert length(crontab) == 3

      assert {"*/15 * * * *", Hiraeth.Oban.ProviderSchedulerWorker} in crontab
      assert {"0 4 * * 0", Hiraeth.Oban.CoverRefreshWorker} in crontab
      assert {"30 4 * * 0", Hiraeth.Oban.ProvenanceAuditWorker} in crontab
    end
  end

  describe "devenv dev guard" do
    test "devenv.nix env block pins HIRAETH_SCHEDULED_INGEST=false so `devenv up` never auto-fetches" do
      devenv_nix = File.read!(Path.join(@repo_root, "devenv.nix"))

      assert devenv_nix =~ ~s(HIRAETH_SCHEDULED_INGEST = "false"),
             "devenv.nix must set HIRAETH_SCHEDULED_INGEST=false so local dev never auto-fetches publisher sites"
    end
  end

  defp read_oban_plugins do
    config = Config.Reader.read!(@runtime_config_path, env: :prod)
    Keyword.fetch!(config[:hiraeth][Oban], :plugins)
  end

  defp read_crontab do
    plugins = read_oban_plugins()

    {Oban.Plugins.Cron, cron_config} =
      Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

    Keyword.fetch!(cron_config, :crontab)
  end
end
