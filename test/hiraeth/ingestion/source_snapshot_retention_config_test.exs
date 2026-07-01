defmodule Hiraeth.Ingestion.SourceSnapshotRetentionConfigTest do
  use ExUnit.Case, async: false

  test "test environment retention root does not write runtime snapshots into priv" do
    root =
      :hiraeth
      |> Application.fetch_env!(:source_snapshot_retention_root)
      |> Path.expand()

    refute String.starts_with?(root, Path.expand("priv/source_snapshots"))
  end
end
