defmodule Hiraeth.Ingestion.ScheduledApplyTest do
  @moduledoc """
  Scheduled-run apply contract: scheduled jobs auto-approve quarantine-clear
  new/changed/unchanged candidates, apply them non-destructively, and can
  NEVER tombstone — removed/invalid/destructive candidates stay quarantined.
  Manually approved removals still tombstone on operator runs (regression).
  """

  use Hiraeth.DataCase, async: false

  @moduletag :reset_committed_catalog
  @moduletag :integration
  @moduletag :slow

  alias Hiraeth.Catalog.Edition
  alias Hiraeth.Ingestion.Phases.ApplyCandidates
  alias Hiraeth.Ingestion.{ProviderManifest, ProviderRun, ProviderSource, RecordCandidate}
  alias Hiraeth.Oban.ProviderIngestionWorker
  alias Hiraeth.RealCatalog.Importer
  alias Hiraeth.Sources.SourceRecord
  alias Hiraeth.TestSupport.ApplyPhaseRegressionHelpers, as: Regression
  alias Hiraeth.TestSupport.IngestionFixtures

  require Ash.Query

  @provider "scheduled_fixture_provider"
  @valid_api_manifest_path Path.join([
                             File.cwd!(),
                             "test/support/fixtures/provider_manifests/valid_api_manifest.json"
                           ])

  # --- Mock modules (e2e_ingestion_test harness pattern) ---

  defmodule FullFetchSidecarClient do
    @moduledoc false

    @fixture_path Path.join([File.cwd!(), "test/fixtures/provider_seed/e2e_provider.json"])
    @provider "scheduled_fixture_provider"

    def health(_opts \\ []), do: {:ok, %{status: "ok", scrapling: true}}

    def fetch(_provider_config, _opts \\ []) do
      {:ok, %{records: records()}}
    end

    def records do
      @fixture_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("records")
      |> Enum.map(&retag_provider/1)
      |> Enum.map(&atomize_record/1)
    end

    def scrape(_provider_config, _opts \\ []),
      do: {:error, "scrape not supported for fixture provider"}

    defp retag_provider(record) do
      field_sources =
        record
        |> Map.get("field_sources", %{})
        |> Map.new(fn {key, field_source} ->
          {key, Map.put(field_source, "provider", @provider)}
        end)

      cover = record |> Map.get("cover", %{}) |> Map.put("provider", @provider)

      record
      |> Map.put("field_sources", field_sources)
      |> Map.put("cover", cover)
    end

    defp atomize_record(record) when is_map(record) do
      Map.new(record, fn
        {"field_sources", value} -> {:field_sources, atomize_field_sources(value)}
        {key, value} -> {String.to_atom(key), atomize_value(value)}
      end)
    end

    defp atomize_field_sources(map) when is_map(map) do
      Map.new(map, fn {key, value} -> {key, atomize_value(value)} end)
    end

    defp atomize_value(map) when is_map(map) do
      Map.new(map, fn {key, value} -> {String.to_atom(key), atomize_value(value)} end)
    end

    defp atomize_value(list) when is_list(list), do: Enum.map(list, &atomize_value/1)
    defp atomize_value(value), do: value
  end

  defmodule SubsetFetchSidecarClient do
    @moduledoc "Returns the fixture catalog minus one record to force a removal diff."

    def health(_opts \\ []), do: {:ok, %{status: "ok", scrapling: true}}

    def fetch(_provider_config, _opts \\ []) do
      records =
        FullFetchSidecarClient.records()
        |> Enum.reject(&String.ends_with?(&1.source_uri, "/books/silent-waters"))

      {:ok, %{records: records}}
    end

    def scrape(_provider_config, _opts \\ []),
      do: {:error, "scrape not supported for fixture provider"}
  end

  defmodule MockCoverPipeline do
    def download_and_cache!(_cover_urls, _provider_config), do: {:ok, %{}}
  end

  defmodule MockImporter do
    def seed_provider!(dataset, import_run) do
      Importer.seed_provider!(dataset, import_run)
    end
  end

  defmodule NoopImporter do
    def seed_provider!(dataset, _import_run) do
      {:ok,
       %{
         publishers: 0,
         editions: length(dataset.records),
         source_records: length(dataset.records)
       }}
    end
  end

  # --- Setup ---

  setup do
    manifest_path = write_temp_manifest!()

    Application.put_env(:hiraeth, :sidecar_client, FullFetchSidecarClient)
    Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
    Application.put_env(:hiraeth, :importer, MockImporter)

    on_exit(fn ->
      Application.delete_env(:hiraeth, :sidecar_client)
      Application.delete_env(:hiraeth, :cover_pipeline)
      Application.delete_env(:hiraeth, :importer)
      File.rm_rf!(Path.dirname(manifest_path))
    end)

    {:ok, manifest_path: manifest_path}
  end

  # --- Full pipeline: scheduled apply ---

  @tag timeout: 120_000
  test "scheduled run applies new/changed candidates and never tombstones", %{
    manifest_path: manifest_path
  } do
    source = create_scheduled_source!(manifest_path)
    run = create_scheduled_run!(source, "2026-08-05T12:00:00Z")

    args = scheduled_args(manifest_path, source, run)

    assert {:ok, summary} = Oban.Testing.perform_job(ProviderIngestionWorker, args, [])
    assert summary.provider == @provider
    assert summary.record_count == 5

    reloaded = Ash.get!(ProviderRun, run.id, authorize?: false)
    assert reloaded.status == "succeeded"
    assert reloaded.finished_at != nil

    source_records = source_records_for(@provider)
    assert source_records != []
    assert length(source_records) == 5
    assert Enum.all?(source_records, &(&1.source_type == "publisher_dataset"))

    assert Ash.read!(Edition, authorize?: false) |> length() == 5

    assert tombstone_records() == []
  end

  @tag timeout: 120_000
  test "scheduled run with a deletion diff leaves the catalog unchanged and quarantines the removal",
       %{manifest_path: manifest_path} do
    source = create_scheduled_source!(manifest_path)
    first_run = create_scheduled_run!(source, "2026-08-05T12:00:00Z")

    assert {:ok, _summary} =
             Oban.Testing.perform_job(
               ProviderIngestionWorker,
               scheduled_args(manifest_path, source, first_run),
               []
             )

    edition_count = Ash.read!(Edition, authorize?: false) |> length()
    source_record_count = source_records_for(@provider) |> length()
    assert edition_count == 5
    assert source_record_count == 5

    # The provider catalog shrinks by one record on the next scheduled fetch.
    Application.put_env(:hiraeth, :sidecar_client, SubsetFetchSidecarClient)
    second_run = create_scheduled_run!(source, "2026-08-06T12:00:00Z")

    assert {:ok, _summary} =
             Oban.Testing.perform_job(
               ProviderIngestionWorker,
               scheduled_args(manifest_path, source, second_run),
               []
             )

    reloaded = Ash.get!(ProviderRun, second_run.id, authorize?: false)
    assert reloaded.status == "succeeded"

    assert [removed] = candidates_for(second_run, "removed")
    assert removed.quarantine_status == "quarantined"
    assert removed.review_decision == "pending_review"

    # Catalog is unchanged: no deletes, no tombstones, no duplicate imports.
    assert Ash.read!(Edition, authorize?: false) |> length() == edition_count
    assert source_records_for(@provider) |> length() == source_record_count
    assert tombstone_records() == []
  end

  # --- Scheduled auto-approval step mechanism ---

  test "scheduled auto-approval approves only pending-review, quarantine-clear candidates" do
    source = IngestionFixtures.create_provider_source!("scheduled-approval")
    run = IngestionFixtures.create_provider_run!(source, "scheduled-approval")
    snapshot = IngestionFixtures.create_source_snapshot!(source, run, "scheduled-approval")

    new_candidate = create_candidate!(run, snapshot, "sched-new", "new")
    changed_candidate = create_candidate!(run, snapshot, "sched-changed", "changed")
    unchanged_candidate = create_candidate!(run, snapshot, "sched-unchanged", "unchanged")
    removed_candidate = create_candidate!(run, snapshot, "sched-removed", "removed")
    invalid_candidate = create_candidate!(run, snapshot, "sched-invalid", "invalid")
    destructive_candidate = create_candidate!(run, snapshot, "sched-destructive", "destructive")

    rejected_candidate =
      create_candidate!(run, snapshot, "sched-rejected", "new", review_decision: "rejected")

    assert {:ok, 3} = ProviderIngestionWorker.auto_approve_scheduled_candidates(run.id)

    for candidate <- [new_candidate, changed_candidate, unchanged_candidate] do
      reloaded = Ash.get!(RecordCandidate, candidate.id, authorize?: false)
      assert reloaded.review_decision == "approved"
      assert reloaded.review_status == "accepted"
      assert reloaded.quarantine_status == "clear"
      assert reloaded.review_actor_id == "provider_scheduler"
      assert reloaded.reviewer_note =~ "scheduled"
    end

    for candidate <- [removed_candidate, invalid_candidate, destructive_candidate] do
      reloaded = Ash.get!(RecordCandidate, candidate.id, authorize?: false)
      assert reloaded.quarantine_status == "quarantined"
      assert reloaded.review_decision == "pending_review"
    end

    reloaded_rejected = Ash.get!(RecordCandidate, rejected_candidate.id, authorize?: false)
    assert reloaded_rejected.review_decision == "rejected"

    # The approved, non-destructive candidates apply; nothing tombstones.
    Application.put_env(:hiraeth, :importer, NoopImporter)
    manifest = ProviderManifest.load!(@valid_api_manifest_path)

    assert {:ok, context} =
             ApplyCandidates.run(%{provider_run_id: run.id, manifest: manifest})

    assert length(context.applied_candidates) == 3
    assert context.tombstone_records == []
    assert tombstone_records() == []
  end

  test "auto-approval is idempotent for already-approved candidates" do
    source = IngestionFixtures.create_provider_source!("scheduled-idempotent")
    run = IngestionFixtures.create_provider_run!(source, "scheduled-idempotent")
    snapshot = IngestionFixtures.create_source_snapshot!(source, run, "scheduled-idempotent")

    _candidate = create_candidate!(run, snapshot, "sched-approved", "new")

    assert {:ok, 1} = ProviderIngestionWorker.auto_approve_scheduled_candidates(run.id)
    assert {:ok, 0} = ProviderIngestionWorker.auto_approve_scheduled_candidates(run.id)
  end

  # --- Regression lock: operator tombstone path is byte-identical ---

  @tag timeout: 120_000
  test "manually approved removed candidate still tombstones on operator runs" do
    %{run: run, snapshot: snapshot, manifest: manifest} =
      Regression.setup_context("task16-manual-tombstone")

    removed = Regression.removed_candidate!(run, snapshot, "task16-manual-tombstone")

    removed
    |> Ash.Changeset.for_update(:accept, %{
      reviewer_note: "Operator approved removal.",
      review_actor_id: "operator",
      reviewed_at: DateTime.utc_now(:second)
    })
    |> Ash.update!(actor: IngestionFixtures.catalog_writer())

    assert {:ok, applied} = ApplyCandidates.run(Regression.context(run, manifest))

    assert [tombstone] = applied.tombstone_records
    assert tombstone.source_type == "publisher_tombstone"
    assert tombstone.provider == manifest.provider

    assert [_ledger_entry] =
             Hiraeth.Sources.SourceLedgerEntry
             |> Ash.read!(authorize?: false)
             |> Enum.filter(&(&1.event_type == "ingestion_tombstone_recorded"))
  end

  # --- Helpers ---

  defp scheduled_args(manifest_path, source, run) do
    %{
      "provider" => @provider,
      "manifest_path" => manifest_path,
      "provider_source_id" => source.id,
      "provider_run_id" => run.id,
      "scheduled" => true
    }
  end

  defp create_scheduled_source!(manifest_path) do
    ProviderSource
    |> Ash.Changeset.for_create(:create, %{
      stable_source_key: @provider,
      provider_name: "Scheduled Fixture Provider",
      source_kind: "publisher",
      ingestion_mode: "api",
      base_uri: "https://fixture.example.com/books",
      manifest_uri: manifest_path,
      allowed_hosts: ["fixture.example.com"],
      rate_limit_per_minute: 30,
      max_bytes: 1_048_576,
      checksum_algorithm: "sha256",
      required_checksum: "sha256:scheduled-fixture-provider",
      license_note: "Deterministic fixture data for scheduled ingestion tests.",
      enabled?: true,
      cadence_hours: 24
    })
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  defp create_scheduled_run!(source, tick_at) do
    ProviderRun
    |> Ash.Changeset.for_create(:create, %{
      provider_source_id: source.id,
      status: "queued",
      requested_by: "provider_scheduler",
      run_key: "scheduled:#{tick_at}",
      provenance: %{"scheduled" => true, "destructive_apply" => false}
    })
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  defp create_candidate!(run, snapshot, suffix, diff_classification, attrs \\ %{}) do
    metadata = %{
      "title" => "Scheduled Fixture Book #{suffix}",
      "isbn_13" => "9781646050001",
      "publisher_name" => "Scheduled Fixture Provider",
      "contributors" => [%{"name" => "Scheduled Author", "role" => "author"}]
    }

    attrs =
      %{
        provider_run_id: run.id,
        source_snapshot_id: snapshot.id,
        candidate_identity: "scheduled_fixture_provider:#{suffix}",
        record_type: "edition",
        source_uri: "https://fixture.example.com/books/#{suffix}",
        diff_classification: diff_classification,
        raw_metadata: metadata,
        normalized_metadata: metadata,
        validation_errors: [],
        validation_findings: []
      }
      |> Map.merge(Map.new(attrs))

    RecordCandidate
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  defp candidates_for(run, diff_classification) do
    RecordCandidate
    |> Ash.Query.filter(
      provider_run_id == ^run.id and diff_classification == ^diff_classification
    )
    |> Ash.read!(authorize?: false)
  end

  defp source_records_for(provider) do
    SourceRecord
    |> Ash.Query.filter(provider == ^provider)
    |> Ash.read!(authorize?: false)
  end

  defp tombstone_records do
    SourceRecord
    |> Ash.Query.filter(source_type == "publisher_tombstone")
    |> Ash.read!(authorize?: false)
  end

  defp write_temp_manifest! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-scheduled-apply-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "#{@provider}.json")

    manifest = %{
      provider: @provider,
      name: "Scheduled Fixture Provider",
      source_mode: "api",
      source_urls: ["https://fixture.example.com/books"],
      source_hosts: ["fixture.example.com"],
      cover_hosts: ["fixture.example.com"],
      api: %{type: "shopify", endpoint: "https://fixture.example.com/api/graphql"},
      rate_limit: %{max_concurrency: 1, min_delay_ms: 0, max_bytes: 1_048_576},
      permission_basis: "Test fixture for scheduled ingestion tests — deterministic data.",
      takedown_contact: "https://fixture.example.com/contact",
      excluded_content: ["raw_html", "prices", "reviews", "cart_checkout_account"],
      cover_cache_policy: "cache_allowed",
      not_legal_advice: true
    }

    File.write!(path, Jason.encode!(manifest))
    path
  end
end
