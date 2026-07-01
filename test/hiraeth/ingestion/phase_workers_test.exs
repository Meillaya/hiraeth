defmodule Hiraeth.Ingestion.PhaseWorkersTest do
  use Hiraeth.DataCase, async: false

  @moduletag :reset_committed_ingestion

  alias Hiraeth.Ingestion.{
    IngestionEvent,
    Phases,
    ProviderManifest,
    ProviderRun,
    RecordCandidate,
    SourceSnapshot
  }

  alias Hiraeth.Ingestion.Phases.RunState
  alias Hiraeth.Sources.SourceRecord
  alias Hiraeth.TestSupport.IngestionFixtures

  require Ash.Query

  @api_manifest_path Path.join([
                       File.cwd!(),
                       "test/support/fixtures/provider_manifests/valid_api_manifest.json"
                     ])

  defmodule HappySidecarClient do
    def fetch(_provider_config, _opts \\ []) do
      {:ok,
       %{
         records: [
           %{
             source_uri: "https://www.testpublisher.com/books/phase-book",
             publisher: "Test Publisher",
             source_product_id: "phase-book-001",
             work: %{title: "Phase Book", publication_state: "published"},
             edition: %{title: "Phase Book", format: "paperback", isbn_13: nil},
             contributors: [%{name: "Phase Author", role: "author"}],
             curation: %{status: "approved"},
             displayed_fields: ["title", "contributors", "publisher"],
             field_sources: %{
               "title" => source(),
               "contributors" => source(),
               "publisher" => source()
             },
             cover: %{},
             no_cover_reason: "not provided by fixture",
             missing_fields: %{isbn_13: "not provided by fixture"},
             series: [],
             review_links: [],
             editorial_praise: []
           }
         ]
       }}
    end

    def scrape(_provider_config, _opts \\ []), do: {:error, {:parse_failed, "not used"}}

    defp source do
      %{
        provider: "test_publisher_api",
        source_uri: "https://www.testpublisher.com/books/phase-book",
        source_type: "publisher_dataset",
        rights_basis: "test"
      }
    end
  end

  defmodule ParseFailureSidecarClient do
    def fetch(_provider_config, _opts \\ []),
      do: {:error, {:parse_failed, "sidecar parse failed"}}

    def scrape(_provider_config, _opts \\ []),
      do: {:error, {:parse_failed, "sidecar parse failed"}}
  end

  setup do
    previous_client = Application.get_env(:hiraeth, :sidecar_client)
    previous_root = Application.get_env(:hiraeth, :source_snapshot_retention_root)

    root =
      Path.join(System.tmp_dir!(), "hiraeth-phase-workers-#{System.unique_integer([:positive])}")

    Application.put_env(:hiraeth, :source_snapshot_retention_root, root)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:hiraeth, :sidecar_client, previous_client)
      else
        Application.delete_env(:hiraeth, :sidecar_client)
      end

      if previous_root do
        Application.put_env(:hiraeth, :source_snapshot_retention_root, previous_root)
      else
        Application.delete_env(:hiraeth, :source_snapshot_retention_root)
      end

      File.rm_rf!(root)
    end)

    source = IngestionFixtures.create_provider_source!("phase-workers")
    run = IngestionFixtures.create_provider_run!(source, "phase-workers")

    {:ok, source: source, run: run, retention_root: root}
  end

  test "happy phase chain persists run phase events, snapshot, candidates, diff, and no catalog apply",
       %{
         source: source,
         run: run,
         retention_root: retention_root
       } do
    Application.put_env(:hiraeth, :sidecar_client, HappySidecarClient)

    assert {:ok, fetched} =
             Phases.FetchSnapshot.run(%{
               manifest_path: @api_manifest_path,
               provider_source_id: source.id,
               provider_run_id: run.id
             })

    assert {:ok, normalized} = Phases.NormalizeCandidates.run(fetched)
    assert {:ok, validated} = Phases.ValidateCandidates.run(normalized)
    assert {:ok, diffed} = Phases.DiffCandidates.run(validated)

    run = Ash.get!(ProviderRun, run.id, authorize?: false)
    assert run.status == "running"
    assert run.snapshot_count == 1
    assert run.candidate_count == 1
    assert get_in(run.provenance, ["phases", "fetch_snapshot", "status"]) == "succeeded"
    assert get_in(run.provenance, ["phases", "normalize_candidates", "status"]) == "succeeded"
    assert get_in(run.provenance, ["phases", "validate_candidates", "status"]) == "succeeded"
    assert get_in(run.provenance, ["phases", "diff_candidates", "status"]) == "succeeded"

    [snapshot] =
      SourceSnapshot
      |> Ash.Query.filter(provider_run_id == ^run.id)
      |> Ash.read!(authorize?: false)

    assert snapshot.provider_run_id == run.id
    assert snapshot.provider_source_id == source.id
    assert snapshot.source_mode == "api"
    assert snapshot.content_checksum == snapshot.checksum
    assert SourceSnapshot.load_payload!(snapshot) =~ "Phase Book"
    assert SourceSnapshot.private_artifact_path!(snapshot.storage_ref) =~ retention_root

    [candidate] =
      RecordCandidate
      |> Ash.Query.filter(provider_run_id == ^run.id)
      |> Ash.read!(authorize?: false)

    assert candidate.provider_run_id == run.id
    assert candidate.source_snapshot_id == snapshot.id
    assert candidate.diff_classification == "new"
    assert candidate.previous_fingerprint == nil
    assert String.starts_with?(candidate.fingerprint, "sha256:")
    assert candidate.quarantine_status == "clear"
    assert diffed.candidate_count == 1

    events = Ash.read!(IngestionEvent, authorize?: false)

    assert Enum.any?(
             events,
             &(&1.event_kind == "phase:fetch_snapshot" and &1.status == "succeeded")
           )

    assert Enum.any?(
             events,
             &(&1.event_kind == "phase:diff_candidates" and &1.status == "succeeded")
           )

    assert [] =
             SourceRecord
             |> Ash.Query.filter(provider == "test_publisher_api")
             |> Ash.read!(authorize?: false)
  end

  @tag :parse_failure
  test "typed parse failure marks failed phase and run without candidates or catalog apply", %{
    source: source,
    run: run
  } do
    Application.put_env(:hiraeth, :sidecar_client, ParseFailureSidecarClient)

    assert {:error, {:parse_failed, message}} =
             Phases.FetchSnapshot.run(%{
               manifest_path: @api_manifest_path,
               provider_source_id: source.id,
               provider_run_id: run.id
             })

    assert message =~ "sidecar parse failed"

    run = Ash.get!(ProviderRun, run.id, authorize?: false)
    assert run.status == "failed"
    assert run.error_count == 1
    assert get_in(run.provenance, ["phases", "fetch_snapshot", "status"]) == "failed"
    assert get_in(run.provenance, ["phases", "fetch_snapshot", "error", "code"]) == "parse_failed"

    assert [] =
             SourceSnapshot
             |> Ash.Query.filter(provider_run_id == ^run.id)
             |> Ash.read!(authorize?: false)

    assert [] =
             RecordCandidate
             |> Ash.Query.filter(provider_run_id == ^run.id)
             |> Ash.read!(authorize?: false)

    assert [] =
             SourceRecord
             |> Ash.Query.filter(provider == "test_publisher_api")
             |> Ash.read!(authorize?: false)

    [event] =
      IngestionEvent
      |> Ash.Query.filter(provider_run_id == ^run.id)
      |> Ash.read!(authorize?: false)

    assert event.event_kind == "phase:fetch_snapshot"
    assert event.status == "failed"
    assert event.payload["error"]["code"] == "parse_failed"
  end

  test "diff phase is replay-friendly and marks unchanged when fingerprint already exists", %{
    source: source,
    run: run
  } do
    Application.put_env(:hiraeth, :sidecar_client, HappySidecarClient)

    {:ok, fetched} =
      Phases.FetchSnapshot.run(%{
        manifest_path: @api_manifest_path,
        provider_source_id: source.id,
        provider_run_id: run.id
      })

    {:ok, normalized} = Phases.NormalizeCandidates.run(fetched)
    {:ok, validated} = Phases.ValidateCandidates.run(normalized)
    {:ok, _diffed} = Phases.DiffCandidates.run(validated)

    replay_run = IngestionFixtures.create_provider_run!(source, "phase-workers-replay")

    {:ok, replay_fetched} =
      Phases.FetchSnapshot.run(%{
        manifest_path: @api_manifest_path,
        provider_source_id: source.id,
        provider_run_id: replay_run.id
      })

    {:ok, replay_normalized} = Phases.NormalizeCandidates.run(replay_fetched)
    {:ok, replay_validated} = Phases.ValidateCandidates.run(replay_normalized)
    assert {:ok, _replay_diffed} = Phases.DiffCandidates.run(replay_validated)

    candidates =
      RecordCandidate
      |> Ash.Query.filter(provider_run_id == ^replay_run.id)
      |> Ash.read!(authorize?: false)

    assert [%RecordCandidate{diff_classification: "unchanged", previous_fingerprint: previous}] =
             candidates

    assert is_binary(previous)
  end

  test "scheduler-shaped phase list provenance is preserved while phase status is persisted", %{
    run: run
  } do
    run =
      run
      |> Ash.Changeset.for_update(:record_progress, %{
        provenance: %{
          "phases" => ["fetch_snapshot", "normalize_candidates", "review_ready"],
          "destructive_apply" => false
        }
      })
      |> Ash.update!(actor: IngestionFixtures.catalog_writer())

    updated =
      RunState.mark_phase(run.id, :fetch_snapshot, :succeeded, %{
        source_count: 1
      })

    assert updated.status == "running"

    assert updated.provenance["planned_phases"] == [
             "fetch_snapshot",
             "normalize_candidates",
             "review_ready"
           ]

    assert get_in(updated.provenance, ["phases", "fetch_snapshot", "status"]) == "succeeded"
  end

  @tag :retry
  test "retrying a failed early phase restores coherent non-terminal run state", %{run: run} do
    failed =
      RunState.mark_phase(run.id, :fetch_snapshot, :failed, %{
        error_count: 1,
        error: %{code: :parse_failed, message: "first attempt failed"},
        message: "fetch_snapshot failed: first attempt failed"
      })

    assert failed.status == "failed"
    assert failed.finished_at
    assert get_in(failed.provenance, ["phases", "fetch_snapshot", "status"]) == "failed"

    retried =
      RunState.mark_phase(run.id, :fetch_snapshot, :succeeded, %{
        source_count: 1,
        snapshot_count: 1,
        message: "fetch_snapshot succeeded after retry"
      })

    assert retried.status == "running"
    assert retried.finished_at == nil
    assert get_in(retried.provenance, ["phases", "fetch_snapshot", "status"]) == "succeeded"

    phase_events =
      IngestionEvent
      |> Ash.Query.filter(provider_run_id == ^run.id and event_kind == "phase:fetch_snapshot")
      |> Ash.read!(authorize?: false)

    assert Enum.any?(phase_events, &(&1.status == "failed"))
    assert Enum.any?(phase_events, &(&1.status == "succeeded"))
  end

  test "fetch failure marks internally created provider run failed" do
    Application.put_env(:hiraeth, :sidecar_client, ParseFailureSidecarClient)

    assert {:error, {:parse_failed, _message}} =
             Phases.FetchSnapshot.run(%{manifest_path: @api_manifest_path})

    failed_runs =
      ProviderRun
      |> Ash.Query.filter(status == "failed" and requested_by == "provider_ingestion_worker")
      |> Ash.read!(authorize?: false)

    run =
      Enum.find(failed_runs, fn run ->
        get_in(run.provenance, ["manifest_provider"]) == "test_publisher_api" and
          get_in(run.provenance, ["phases", "fetch_snapshot", "status"]) == "failed"
      end)

    assert %ProviderRun{} = run
    assert get_in(run.provenance, ["phases", "fetch_snapshot", "status"]) == "failed"

    assert Enum.any?(
             Ash.read!(IngestionEvent, authorize?: false),
             &(&1.provider_run_id == run.id and &1.event_kind == "phase:fetch_snapshot" and
                 &1.status == "failed")
           )
  end

  test "normalize failure persists failed phase status and event", %{run: run} do
    manifest = ProviderManifest.load!(@api_manifest_path)

    assert {:error, {:normalize_failed, _message}} =
             Phases.NormalizeCandidates.run(%{
               manifest: manifest,
               provider_run_id: run.id,
               raw_records: :invalid_records
             })

    assert_phase_failed(run.id, :normalize_candidates, "normalize_failed")
  end

  test "validate failure persists failed phase status and event", %{source: source, run: run} do
    Application.put_env(:hiraeth, :sidecar_client, HappySidecarClient)

    {:ok, fetched} =
      Phases.FetchSnapshot.run(%{
        manifest_path: @api_manifest_path,
        provider_source_id: source.id,
        provider_run_id: run.id
      })

    {:ok, normalized} = Phases.NormalizeCandidates.run(fetched)
    manifest = Map.put(normalized.manifest, :expected_record_count, 2)

    assert {:error, reason} =
             normalized
             |> Map.put(:manifest, manifest)
             |> Phases.ValidateCandidates.run()

    assert reason =~ "expected_record_count 2"
    assert_phase_failed(run.id, :validate_candidates, "validation_failed")
  end

  test "diff failure persists failed phase status and event", %{source: source, run: run} do
    Application.put_env(:hiraeth, :sidecar_client, HappySidecarClient)

    {:ok, fetched} =
      Phases.FetchSnapshot.run(%{
        manifest_path: @api_manifest_path,
        provider_source_id: source.id,
        provider_run_id: run.id
      })

    {:ok, normalized} = Phases.NormalizeCandidates.run(fetched)
    {:ok, validated} = Phases.ValidateCandidates.run(normalized)

    assert {:error, {:diff_failed, _message}} =
             validated
             |> Map.put(:source_snapshot, nil)
             |> Phases.DiffCandidates.run()

    assert [] =
             RecordCandidate
             |> Ash.Query.filter(provider_run_id == ^run.id)
             |> Ash.read!(authorize?: false)

    assert_phase_failed(run.id, :diff_candidates, "diff_failed")
  end

  defp assert_phase_failed(run_id, phase, code) do
    phase = Atom.to_string(phase)
    run = Ash.get!(ProviderRun, run_id, authorize?: false)

    assert run.status == "failed"
    assert run.error_count == 1
    assert get_in(run.provenance, ["phases", phase, "status"]) == "failed"
    assert get_in(run.provenance, ["phases", phase, "error", "code"]) == code

    assert Enum.any?(
             Ash.read!(IngestionEvent, authorize?: false),
             &(&1.provider_run_id == run_id and &1.event_kind == "phase:#{phase}" and
                 &1.status == "failed")
           )
  end
end
