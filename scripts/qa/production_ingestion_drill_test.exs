defmodule HiraethQA.ProductionIngestionDrillTest do
  use Hiraeth.DataCase, async: false

  import Hiraeth.TestSupport.ApplyPhaseRegressionHelpers

  alias Hiraeth.Ingestion.{Phases, SourceSnapshot}
  alias Hiraeth.TestSupport.IngestionFixtures

  @moduletag :capture_log

  setup do
    context = setup_context("t25-drill-#{System.unique_integer([:positive])}")

    root =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-t25-drill-#{System.unique_integer([:positive])}"
      )

    previous_root = Application.get_env(:hiraeth, :source_snapshot_retention_root)
    Application.put_env(:hiraeth, :source_snapshot_retention_root, root)

    on_exit(fn ->
      if previous_root do
        Application.put_env(:hiraeth, :source_snapshot_retention_root, previous_root)
      else
        Application.delete_env(:hiraeth, :source_snapshot_retention_root)
      end

      File.rm_rf!(root)
      IO.puts("PASS cleanup removed replay retention root #{root}")
    end)

    {:ok, Map.put(context, :retention_root, root)}
  end

  @tag :provider_replay
  test "provider replay from retained snapshot reconstructs expected catalog records", %{
    source: source,
    run: run,
    manifest: manifest
  } do
    records = [catalog_record("t25-replay-a"), catalog_record("t25-replay-b")]
    payload = Jason.encode!(%{"records" => records})

    retained =
      SourceSnapshot.retain_artifact!(
        manifest.provider,
        "https://example.test/t25-replay.json",
        payload,
        extension: ".json"
      )

    snapshot =
      SourceSnapshot
      |> Ash.Changeset.for_create(:create, %{
        provider_source_id: source.id,
        provider_run_id: run.id,
        provider: manifest.provider,
        source_url: "https://example.test/t25-replay.json",
        checksum: retained.checksum,
        fetched_at: DateTime.utc_now(:second),
        content_type: "application/json",
        byte_size: retained.byte_size,
        raw_payload: %{"records" => records},
        source_mode: "api",
        artifact_path: retained.artifact_path
      })
      |> Ash.create!(actor: IngestionFixtures.catalog_writer())

    replayed = Phases.ReplaySnapshot.from_snapshot(snapshot)

    assert Enum.map(replayed, & &1["source_product_id"]) == [
             "apply-phase-t25-replay-a",
             "apply-phase-t25-replay-b"
           ]

    assert Enum.all?(replayed, &match?(%{"field_sources" => %{}}, &1))

    IO.puts(
      "PASS provider replay from snapshot reconstructed expected catalog state count=#{length(replayed)} checksum=#{retained.checksum}"
    )
  end

  @tag :replay_load_idempotency
  test "bounded replay load is idempotent and reports elapsed counts", %{
    run: run,
    snapshot: snapshot,
    manifest: manifest
  } do
    candidate_a = approved_candidate!(run, snapshot, "t25-load-a")
    candidate_b = approved_candidate!(run, snapshot, "t25-load-b")

    started = System.monotonic_time(:millisecond)

    results =
      for _iteration <- 1..12 do
        assert {:ok, replayed_context} = Phases.ReplaySnapshot.run(context(run, manifest))

        replayed_context.replay_records
        |> Enum.map(&payload_value(&1["ingestion_candidate"], "candidate_id"))
        |> Enum.sort()
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started
    expected_ids = Enum.sort([candidate_a.id, candidate_b.id])

    assert Enum.all?(results, &(&1 == expected_ids))

    IO.puts(
      "PASS load/replay idempotency iterations=12 records_per_iteration=2 elapsed_ms=#{elapsed_ms} candidate_ids=#{Enum.join(expected_ids, ",")}"
    )
  end
end
