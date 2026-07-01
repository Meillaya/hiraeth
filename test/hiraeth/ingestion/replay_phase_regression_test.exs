defmodule Hiraeth.Ingestion.ReplayPhaseRegressionTest do
  use Hiraeth.DataCase, async: false

  import Hiraeth.TestSupport.ApplyPhaseRegressionHelpers

  alias Hiraeth.Ingestion.{Phases, SourceSnapshot}
  alias Hiraeth.TestSupport.IngestionFixtures

  @moduletag :capture_log

  setup do
    setup_context("replay-regression")
  end

  test "replay reconstructs retained snapshot and approved candidate payload provenance", %{
    source: source,
    run: run,
    snapshot: candidate_snapshot,
    manifest: manifest
  } do
    root =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-replay-regression-#{System.unique_integer([:positive])}"
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
    end)

    payload = Jason.encode!(%{"records" => [catalog_record("snapshot-replay")]})

    retained =
      SourceSnapshot.retain_artifact!(
        manifest.provider,
        "https://example.test/catalog.json",
        payload,
        extension: ".json"
      )

    snapshot =
      SourceSnapshot
      |> Ash.Changeset.for_create(:create, %{
        provider_source_id: source.id,
        provider_run_id: run.id,
        provider: manifest.provider,
        source_url: "https://example.test/catalog.json",
        checksum: retained.checksum,
        fetched_at: DateTime.utc_now(:second),
        content_type: "application/json",
        byte_size: retained.byte_size,
        raw_payload: %{"records" => [catalog_record("snapshot-replay")]},
        source_mode: "api",
        artifact_path: retained.artifact_path
      })
      |> Ash.create!(actor: IngestionFixtures.catalog_writer())

    assert [%{"source_product_id" => "apply-phase-snapshot-replay"}] =
             Phases.ReplaySnapshot.from_snapshot(snapshot)

    candidate = approved_candidate!(run, candidate_snapshot, "candidate-replay")
    assert {:ok, replayed} = Phases.ReplaySnapshot.run(context(run, manifest))
    assert [record] = replayed.replay_records
    assert payload_value(record["ingestion_candidate"], "candidate_id") == candidate.id

    assert payload_value(record["ingestion_candidate"], "source_snapshot_id") ==
             candidate_snapshot.id
  end
end
