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
