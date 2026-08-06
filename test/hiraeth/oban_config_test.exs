defmodule Hiraeth.ObanConfigTest do
  use Hiraeth.DataCase, async: true

  test "Oban starts successfully with start_supervised!" do
    oban_config =
      Application.fetch_env!(:hiraeth, Oban)
      |> Keyword.put(:name, Oban.TestOban)
      |> Keyword.put(:queues, false)
      |> Keyword.put(:plugins, false)

    pid = start_supervised!({Oban, oban_config})
    assert is_pid(pid)
  end

  test "Oban crontab schedules the weekly cover refresh and provenance audit beside the scheduler tick" do
    oban_config = Application.fetch_env!(:hiraeth, Oban)

    crontab =
      case Enum.find(oban_config[:plugins], &match?({Oban.Plugins.Cron, _}, &1)) do
        {Oban.Plugins.Cron, cron_config} -> Keyword.fetch!(cron_config, :crontab)
        nil -> []
      end

    # The devenv dev guard exports HIRAETH_SCHEDULED_INGEST=false, which
    # runtime.exs honors by dropping all autonomous cron entries. The full
    # true/false matrix is pinned by Hiraeth.ObanConfigKillSwitchTest via
    # Config.Reader against the release-boot path.
    if System.get_env("HIRAETH_SCHEDULED_INGEST", "true") == "false" do
      assert crontab == []
    else
      assert {"*/15 * * * *", Hiraeth.Oban.ProviderSchedulerWorker} in crontab
      assert {"0 4 * * 0", Hiraeth.Oban.CoverRefreshWorker} in crontab
      assert {"30 4 * * 0", Hiraeth.Oban.ProvenanceAuditWorker} in crontab
    end
  end

  test "oban_jobs table exists in the database" do
    assert {:ok, %{rows: rows}} =
             Hiraeth.Repo.query(
               """
               select table_name
               from information_schema.tables
               where table_schema = 'public' and table_name = 'oban_jobs'
               """,
               []
             )

    assert [["oban_jobs"]] = rows
  end
end
