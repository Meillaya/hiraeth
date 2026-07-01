defmodule Hiraeth.Ingestion.E2EIngestionTest do
  use Hiraeth.DataCase, async: false

  @moduletag :reset_committed_catalog

  import Ecto.Query

  alias Hiraeth.Catalog.{
    Contribution,
    Edition,
    Identifier,
    Imprint,
    Publisher,
    Work
  }

  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  require Ash.Query

  @manifest_path Path.join([File.cwd!(), "test/fixtures/manifests/fixture_provider.json"])
  @fixture_dataset_path Path.join([File.cwd!(), "test/fixtures/provider_seed/e2e_provider.json"])

  # --- Mock modules ---

  defmodule MockSidecarClient do
    def health(_opts \\ []) do
      {:ok, %{status: "ok", scrapling: true}}
    end

    def fetch(_provider_config, _opts \\ []) do
      fixture_path = Path.join([File.cwd!(), "test/fixtures/provider_seed/e2e_provider.json"])
      decoded = fixture_path |> File.read!() |> Jason.decode!()
      records = decoded["records"] |> Enum.map(&atomize_record/1)
      {:ok, %{records: records}}
    end

    def scrape(_provider_config, _opts \\ []) do
      {:error, "scrape not supported for fixture provider"}
    end

    defp atomize_record(record) when is_map(record) do
      Map.new(record, fn
        {"field_sources", value} -> {:field_sources, atomize_field_sources(value)}
        {key, value} -> {String.to_atom(key), atomize_value(value)}
      end)
    end

    # field_sources: top-level keys become atoms, inner keys stay strings
    defp atomize_field_sources(map) when is_map(map) do
      Map.new(map, fn {key, value} -> {key, atomize_value(value)} end)
    end

    defp atomize_value(map) when is_map(map) do
      Map.new(map, fn {key, value} -> {String.to_atom(key), atomize_value(value)} end)
    end

    defp atomize_value(list) when is_list(list) do
      Enum.map(list, &atomize_value/1)
    end

    defp atomize_value(value), do: value
  end

  defmodule MockCoverPipeline do
    def download_and_cache!(_cover_urls, _provider_config) do
      {:ok, %{}}
    end
  end

  defmodule MockImporter do
    def seed_provider!(dataset, import_run) do
      Hiraeth.RealCatalog.Importer.seed_provider!(dataset, import_run)
    end
  end

  # --- Test setup ---

  setup do
    # Create temp directory with fixture dataset for the importer
    tmp_dir =
      Path.join(System.tmp_dir!(), "hiraeth-e2e-ingestion-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Copy fixture dataset to temp dir so Dataset.load_dir can find it
    File.cp!(@fixture_dataset_path, Path.join(tmp_dir, "e2e_provider.json"))

    # Set up injectable mocks
    Application.put_env(:hiraeth, :sidecar_client, MockSidecarClient)
    Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
    Application.put_env(:hiraeth, :importer, MockImporter)
    Process.put(:e2e_fixture_dir, tmp_dir)

    # Configure Oban for inline testing
    previous_oban_config = Application.get_env(:hiraeth, Oban)

    Application.put_env(
      :hiraeth,
      Oban,
      Keyword.put(previous_oban_config || [], :testing, :inline)
    )

    on_exit(fn ->
      Application.delete_env(:hiraeth, :sidecar_client)
      Application.delete_env(:hiraeth, :cover_pipeline)
      Application.delete_env(:hiraeth, :importer)
      Application.put_env(:hiraeth, Oban, previous_oban_config)
      Process.delete(:e2e_fixture_dir)
      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  # --- Tests ---

  @tag timeout: 120_000
  test "full ingestion pipeline: manifest → sidecar → validate → covers → import → audit" do
    clear_catalog!()

    job = %Oban.Job{args: %{"manifest_path" => @manifest_path}}
    assert {:ok, result} = Hiraeth.Oban.ProviderIngestionWorker.perform(job)

    assert result.provider == "fixture_test_provider"
    assert result.record_count == 5
    assert result.source_mode == "api"

    # Verify editions exist with correct titles
    editions = Ash.read!(Edition, authorize?: false)
    assert length(editions) == 5

    titles = Enum.map(editions, & &1.title)
    assert "The Glass Bridge" in titles
    assert "Echoes of Tomorrow" in titles
    assert "The Last Garden" in titles
    assert "Winds of Change" in titles
    assert "Silent Waters" in titles

    # Verify formats
    formats = Enum.map(editions, & &1.format)
    assert Enum.count(formats, &(&1 == "paperback")) == 3
    assert Enum.count(formats, &(&1 == "hardcover")) == 2

    # Verify publisher exists
    publishers = Ash.read!(Publisher, authorize?: false)
    assert length(publishers) == 1
    assert hd(publishers).name == "Fixture Press"

    # Verify imprint exists
    imprints = Ash.read!(Imprint, authorize?: false)
    assert length(imprints) == 1
    assert hd(imprints).name == "Fixture Classics"

    # Verify identifiers exist (one ISBN per edition)
    identifiers = Ash.read!(Identifier, authorize?: false)
    assert length(identifiers) == 5

    isbns = Enum.map(identifiers, & &1.value) |> Enum.sort()

    assert isbns == [
             "9780000000040",
             "9780000000057",
             "9780000000064",
             "9780000000071",
             "9780000000088"
           ]

    # Verify SourceRecords exist with correct provider
    source_records = Ash.read!(SourceRecord, authorize?: false)
    assert length(source_records) == 5

    assert Enum.all?(source_records, &(&1.provider == "fixture_test_provider"))
    assert Enum.all?(source_records, &(&1.source_type == "publisher_dataset"))
    assert Enum.all?(source_records, &is_binary(&1.source_uri))
    assert Enum.all?(source_records, &is_binary(&1.edition_id))
    assert Enum.all?(source_records, &is_binary(&1.import_run_id))
    assert Enum.all?(source_records, &is_binary(&1.source_identity))
    assert Enum.all?(source_records, &is_binary(&1.file_checksum))

    # Verify SourceLedgerEntries exist
    ledger_entries = Ash.read!(SourceLedgerEntry, authorize?: false)
    assert length(ledger_entries) >= 5

    assert Enum.all?(ledger_entries, &(&1.event_type == "real_catalog_seeded"))

    # Verify CoverAssets exist (all 5 records have covers)
    cover_assets = Ash.read!(CoverAsset, authorize?: false)
    assert length(cover_assets) == 5

    assert Enum.all?(cover_assets, &(&1.provider == "fixture_test_provider"))
    assert Enum.all?(cover_assets, &(&1.cache_policy == "cache_allowed"))
    assert Enum.all?(cover_assets, &(&1.rights_basis == "local_cache_permitted"))
    assert Enum.all?(cover_assets, &(&1.takedown_state == "visible"))

    # Verify CoverAssignments exist
    cover_assignments = Ash.read!(CoverAssignment, authorize?: false)
    assert length(cover_assignments) == 5

    assert Enum.all?(cover_assignments, & &1.visible?)

    # Verify ImportRun exists
    import_runs = Ash.read!(ImportRun, authorize?: false)
    assert length(import_runs) == 1
    assert hd(import_runs).provider == "fixture_test_provider"

    # Verify contributors exist
    contributions = Ash.read!(Contribution, authorize?: false)
    assert length(contributions) == 7

    # Verify works have correct metadata
    works = Ash.read!(Work, authorize?: false)
    assert length(works) == 5

    last_garden = Enum.find(works, &(&1.title == "The Last Garden"))
    assert last_garden.original_title == "El Ultimo Jardin"
    assert last_garden.original_language_code == "spa"

    silent_waters = Enum.find(works, &(&1.title == "Silent Waters"))
    assert silent_waters.original_title == "Eaux Silencieuses"
    assert silent_waters.original_language_code == "fra"

    # Verify edition with dimensions
    silent_edition = Enum.find(editions, &(&1.title == "Silent Waters"))
    assert silent_edition.height_mm == 210
    assert silent_edition.width_mm == 140
    assert silent_edition.depth_mm == 22
    assert silent_edition.page_count == 256
    assert silent_edition.language_code == "eng"
  end

  @tag timeout: 120_000
  test "idempotency: re-running ingestion does not create duplicates" do
    clear_catalog!()

    job = %Oban.Job{args: %{"manifest_path" => @manifest_path}}

    # First run
    assert {:ok, first_result} = Hiraeth.Oban.ProviderIngestionWorker.perform(job)
    assert first_result.record_count == 5

    edition_count = Ash.read!(Edition, authorize?: false) |> length()
    source_record_count = Ash.read!(SourceRecord, authorize?: false) |> length()
    cover_asset_count = Ash.read!(CoverAsset, authorize?: false) |> length()
    cover_assignment_count = Ash.read!(CoverAssignment, authorize?: false) |> length()
    ledger_count = Ash.read!(SourceLedgerEntry, authorize?: false) |> length()
    import_run_count = Ash.read!(ImportRun, authorize?: false) |> length()

    assert edition_count == 5
    assert source_record_count == 5
    assert cover_asset_count == 5
    assert cover_assignment_count == 5

    # Second run — should skip import due to existing source records
    assert {:ok, second_result} = Hiraeth.Oban.ProviderIngestionWorker.perform(job)
    assert second_result.record_count == 5

    # Counts must be identical — no duplicates
    assert Ash.read!(Edition, authorize?: false) |> length() == edition_count
    assert Ash.read!(SourceRecord, authorize?: false) |> length() == source_record_count
    assert Ash.read!(CoverAsset, authorize?: false) |> length() == cover_asset_count
    assert Ash.read!(CoverAssignment, authorize?: false) |> length() == cover_assignment_count
    assert Ash.read!(SourceLedgerEntry, authorize?: false) |> length() == ledger_count
    assert Ash.read!(ImportRun, authorize?: false) |> length() == import_run_count
  end

  @tag timeout: 120_000
  test "provenance audit passes after ingestion" do
    clear_catalog!()

    job = %Oban.Job{args: %{"manifest_path" => @manifest_path}}
    assert {:ok, _result} = Hiraeth.Oban.ProviderIngestionWorker.perform(job)

    # Run provenance audit
    audit = Hiraeth.ProvenanceAudit.audit!()

    # Verify no missing provenance
    assert audit.missing_provenance == [],
           "expected no missing_provenance, got: #{inspect(audit.missing_provenance)}"

    # Verify no source ledger missing
    assert audit.source_ledger_missing == [],
           "expected no source_ledger_missing, got: #{inspect(audit.source_ledger_missing)}"

    # Verify no invalid public covers
    assert audit.invalid_public_covers == [],
           "expected no invalid_public_covers, got: #{inspect(audit.invalid_public_covers)}"

    # Verify source records and ledger rows match
    assert audit.source_records == 5
    assert audit.source_ledger_rows >= 5
  end

  @tag timeout: 120_000
  test "Mix task invocation with fixture provider ingests successfully" do
    clear_catalog!()

    task =
      Task.async(fn ->
        Mix.Tasks.Hiraeth.Ingest.do_run([
          "--provider",
          "fixture_test_provider",
          "--manifest",
          @manifest_path
        ])
      end)

    # Wait for the job to appear and drain the queue
    _job = wait_for_job!()
    Oban.drain_queue(queue: :ingestion, with_safety: false)

    assert :ok = Task.await(task, 30_000)

    # Verify data was imported
    editions = Ash.read!(Edition, authorize?: false)
    assert length(editions) == 5

    source_records = Ash.read!(SourceRecord, authorize?: false)
    assert length(source_records) == 5
    assert Enum.all?(source_records, &(&1.provider == "fixture_test_provider"))

    cover_assets = Ash.read!(CoverAsset, authorize?: false)
    assert length(cover_assets) == 5

    cover_assignments = Ash.read!(CoverAssignment, authorize?: false)
    assert length(cover_assignments) == 5
  end

  # --- Helpers ---

  defp clear_catalog!, do: Hiraeth.CatalogCleanup.clear_catalog!()

  defp wait_for_job!(timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_job(deadline)
  end

  defp do_wait_for_job(deadline) do
    case Hiraeth.Repo.one(from(j in Oban.Job, where: j.queue == "ingestion", limit: 1)) do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "No job found in ingestion queue within timeout"
        else
          Process.sleep(100)
          do_wait_for_job(deadline)
        end

      job ->
        job
    end
  end
end
