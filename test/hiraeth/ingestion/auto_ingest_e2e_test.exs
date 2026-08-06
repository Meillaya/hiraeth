defmodule Hiraeth.Ingestion.AutoIngestE2ETest do
  @moduledoc """
  End-to-end autonomous ingestion chain, driven through perform/1 and
  Oban.Testing (plugins are disabled in test via testing: :manual):

    1. A cadence-due provider source (cadence_hours 24, last succeeded run
       25h old) ticked by `ProviderSchedulerWorker.perform` gets a queued
       scheduled run and a `ProviderIngestionWorker` job with
       `"scheduled" => true`.
    2. Running that job against the mock sidecar harness applies the fetched
       catalog non-destructively and succeeds the run.
    3. A recent succeeded run (1h old) is not due: no run, no job.
    4. A stale queued scheduled run is adopted per todo 16, not duplicated,
       and its adopted job completes.
  """

  use Hiraeth.DataCase, async: false

  # Deliberately NOT :reset_committed_catalog: the chain evidence is
  # provider-scoped (this file never truncates the shared catalog tables),
  # keeping the full-corpus TRUNCATE contention surface unchanged.
  @moduletag :integration
  @moduletag :slow

  alias Hiraeth.Ingestion.{ProviderRun, ProviderSource}
  alias Hiraeth.Oban.{ProviderIngestionWorker, ProviderSchedulerWorker}
  alias Hiraeth.RealCatalog.Importer
  alias Hiraeth.Sources.SourceRecord
  alias Hiraeth.TestSupport.IngestionFixtures

  import Ecto.Query

  require Ash.Query

  @provider "scheduled_fixture_provider"

  # --- Mock modules (scheduled_apply_test harness pattern) ---

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

  defmodule MockCoverPipeline do
    def download_and_cache!(_cover_urls, _provider_config), do: {:ok, %{}}
  end

  defmodule MockImporter do
    def seed_provider!(dataset, import_run) do
      Importer.seed_provider!(dataset, import_run)
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

  # --- Full chain ---

  @tag timeout: 120_000
  test "cadence-due provider: scheduler tick dispatches a scheduled job that updates the catalog non-destructively",
       %{manifest_path: manifest_path} do
    source = create_scheduled_source!(manifest_path)

    _stale_success =
      create_succeeded_run!(source, "e2e-stale", hours_before(DateTime.utc_now(), 25))

    assert {:ok, summary} = scheduler_tick(source)

    assert [run] = summary.created
    assert [dispatched] = summary.dispatched
    assert dispatched.id == run.id
    assert run.status == "queued"
    assert run.requested_by == "provider_scheduler"
    assert run.provenance["destructive_apply"] == false

    assert [job] = ingestion_jobs()
    assert job.state == "available"
    assert job.args["provider"] == @provider
    assert job.args["manifest_path"] == manifest_path
    assert job.args["provider_source_id"] == source.id
    assert job.args["provider_run_id"] == run.id
    assert job.args["scheduled"] == true

    # Run the dispatched job against the mock sidecar harness.
    assert {:ok, ingest_summary} =
             Oban.Testing.perform_job(ProviderIngestionWorker, job.args, [])

    assert ingest_summary.provider == @provider
    assert ingest_summary.record_count == 5

    reloaded = Ash.get!(ProviderRun, run.id, authorize?: false)
    assert reloaded.status == "succeeded"
    assert reloaded.finished_at != nil

    source_records = source_records_for(@provider)
    assert length(source_records) == 5
    assert Enum.all?(source_records, &(&1.source_type == "publisher_dataset"))

    # Non-destructive: no tombstones from a scheduled run.
    assert tombstone_records() == []
  end

  # --- Negative: cadence respected ---

  test "recent succeeded run (1h ago) is not due: no job, no queued run",
       %{manifest_path: manifest_path} do
    source = create_scheduled_source!(manifest_path)

    _recent_success =
      create_succeeded_run!(source, "e2e-recent", hours_before(DateTime.utc_now(), 1))

    assert {:ok, %{created: [], adopted: [], dispatched: [], skipped: skipped}} =
             scheduler_tick(source)

    assert Enum.find(skipped, &(&1.provider_source_id == source.id)).reason == :not_due

    assert ingestion_jobs() == []
    assert active_runs_for(source) == []
  end

  # --- Stale queued run adoption (todo 16 rule) ---

  @tag timeout: 120_000
  test "stale queued scheduled run is adopted, dispatched, and completes",
       %{manifest_path: manifest_path} do
    source = create_scheduled_source!(manifest_path)
    stale = create_queued_scheduled_run!(source, "scheduled:2026-08-04T09:00:00Z")

    assert {:ok, summary} = scheduler_tick(source)

    assert summary.created == []
    assert [adopted] = summary.adopted
    assert adopted.id == stale.id
    assert [dispatched] = summary.dispatched
    assert dispatched.id == stale.id

    assert [job] = ingestion_jobs()
    assert job.args["provider_run_id"] == stale.id
    assert job.args["scheduled"] == true

    assert {:ok, _ingest_summary} =
             Oban.Testing.perform_job(ProviderIngestionWorker, job.args, [])

    reloaded = Ash.get!(ProviderRun, stale.id, authorize?: false)
    assert reloaded.status == "succeeded"
    assert reloaded.finished_at != nil
  end

  # --- Helpers ---

  defp scheduler_tick(source) do
    %Oban.Job{
      args: %{"provider_source_ids" => [source.id]},
      inserted_at: DateTime.utc_now()
    }
    |> ProviderSchedulerWorker.perform()
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

  defp create_succeeded_run!(source, suffix, finished_at) do
    source
    |> IngestionFixtures.create_provider_run!(suffix)
    |> Ash.Changeset.for_update(:mark_succeeded, %{finished_at: finished_at})
    |> Ash.update!(actor: IngestionFixtures.catalog_writer())
  end

  defp create_queued_scheduled_run!(source, run_key) do
    ProviderRun
    |> Ash.Changeset.for_create(:create, %{
      provider_source_id: source.id,
      status: "queued",
      requested_by: "provider_scheduler",
      run_key: run_key,
      provenance: %{}
    })
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  defp hours_before(now, hours) do
    DateTime.add(now, -hours * 3_600, :second)
  end

  defp ingestion_jobs do
    Hiraeth.Repo.all(from(job in Oban.Job, where: job.queue == "ingestion"))
  end

  defp active_runs_for(source) do
    ProviderRun
    |> Ash.Query.filter(provider_source_id == ^source.id and status in ["queued", "running"])
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
        "hiraeth-auto-ingest-e2e-#{System.unique_integer([:positive])}"
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
