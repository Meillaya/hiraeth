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

    {Oban.Plugins.Cron, cron_config} =
      Enum.find(oban_config[:plugins], &match?({Oban.Plugins.Cron, _}, &1))

    crontab = Keyword.fetch!(cron_config, :crontab)

    assert {"*/15 * * * *", Hiraeth.Oban.ProviderSchedulerWorker} in crontab
    assert {"0 4 * * 0", Hiraeth.Oban.CoverRefreshWorker} in crontab
    assert {"30 4 * * 0", Hiraeth.Oban.ProvenanceAuditWorker} in crontab
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
