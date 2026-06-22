defmodule Hiraeth.Ingestion.ApplyScrapeTaskTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.RealCatalog.Dataset
  alias Hiraeth.Sources.SourceRecord

  require Ash.Query

  @fixture_path Path.join([
                  File.cwd!(),
                  "test/fixtures/provider_seed/valid_provider.json"
                ])

  setup do
    clear_catalog!()
    cleanup_files!("apply_scrape_test_provider")
    cleanup_files!("apply_scrape_prune_provider")

    on_exit(fn ->
      cleanup_files!("apply_scrape_test_provider")
      cleanup_files!("apply_scrape_prune_provider")
    end)

    :ok
  end

  describe "happy path" do
    @tag timeout: 60_000
    test "moves staged file to real_publishers and imports the provider" do
      provider = "apply_scrape_test_provider"
      staged_path = staged_path_for(provider)
      canonical_path = canonical_path_for(provider)

      write_staged_fixture!(provider, @fixture_path)
      assert File.exists?(staged_path)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.ApplyScrape.run([
                     "--provider",
                     provider
                   ])
        end)

      refute File.exists?(staged_path), "staged file should be removed after apply"
      assert File.exists?(canonical_path), "canonical fixture should exist after apply"

      assert {:ok, dataset} = Dataset.load_file(canonical_path)
      assert dataset.provider == provider
      assert length(dataset.records) == 3

      assert output =~ "Applied staged dataset for provider: #{provider}"
      assert output =~ "records_imported=3"
      assert output =~ "source_records_created=3"
      assert output =~ "stale_records_pruned=0"

      source_records =
        SourceRecord
        |> Ash.Query.filter(provider: provider, source_type: "publisher_dataset")
        |> Ash.read!(authorize?: false)

      assert length(source_records) == 3
      assert Enum.all?(source_records, &(&1.file_checksum == dataset.file_checksum))

      import_runs =
        ImportRun
        |> Ash.Query.filter(provider: provider, status: "applied")
        |> Ash.read!(authorize?: false)

      assert length(import_runs) == 1
      assert hd(import_runs).row_limit == 3
    end
  end

  describe "argument validation" do
    test "missing --provider exits 1" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert catch_exit(Mix.Tasks.Hiraeth.ApplyScrape.run([])) == {:shutdown, 1}
        end)

      assert output =~ "Usage: mix hiraeth.apply_scrape"
    end
  end

  describe "staged file validation" do
    test "missing staged file exits 1 with message" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert catch_exit(
                   Mix.Tasks.Hiraeth.ApplyScrape.run([
                     "--provider",
                     "apply_scrape_missing_provider"
                   ])
                 ) == {:shutdown, 1}
        end)

      assert output =~ "Staged dataset not found"
    end
  end

  describe "stale record pruning" do
    @tag timeout: 60_000
    test "re-applying a provider with a different checksum prunes stale source records" do
      provider = "apply_scrape_prune_provider"
      staged_path = staged_path_for(provider)
      canonical_path = canonical_path_for(provider)

      # First apply: seed all three records.
      write_staged_fixture!(provider, @fixture_path)

      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Mix.Tasks.Hiraeth.ApplyScrape.run(["--provider", provider])
      end)

      assert File.exists?(canonical_path)
      refute File.exists?(staged_path)

      source_records =
        SourceRecord
        |> Ash.Query.filter(provider: provider, source_type: "publisher_dataset")
        |> Ash.read!(authorize?: false)

      assert length(source_records) == 3

      # Build a modified staged dataset with only two records (different checksum).
      {:ok, original_dataset} = Dataset.load_file(canonical_path)
      [r1, r2 | _] = original_dataset.records

      slim_dataset = %{
        original_dataset
        | records: [r1, r2],
          file: Path.basename(staged_path),
          file_path: staged_path
      }

      File.write!(staged_path, Jason.encode!(slim_dataset, pretty: true))

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Mix.Tasks.Hiraeth.ApplyScrape.run(["--provider", provider])
        end)

      refute File.exists?(staged_path)
      assert File.exists?(canonical_path)

      assert output =~ "records_imported=2"
      assert output =~ "source_records_created=2"
      assert output =~ "stale_records_pruned=3"

      source_records =
        SourceRecord
        |> Ash.Query.filter(provider: provider, source_type: "publisher_dataset")
        |> Ash.read!(authorize?: false)

      assert length(source_records) == 2
    end
  end

  defp write_staged_fixture!(provider, fixture_path) do
    staged_path = staged_path_for(provider)
    File.mkdir_p!(Path.dirname(staged_path))

    content =
      fixture_path
      |> File.read!()
      |> String.replace("test_provider_official_site", provider)

    File.write!(staged_path, content)
    staged_path
  end

  defp staged_path_for(provider) do
    Application.app_dir(:hiraeth, "priv/catalog_sources/staged/#{provider}.json")
  end

  defp canonical_path_for(provider) do
    Application.app_dir(:hiraeth, "priv/catalog_sources/real_publishers/#{provider}.json")
  end

  defp cleanup_files!(provider) do
    File.rm(staged_path_for(provider))
    File.rm(canonical_path_for(provider))
  end

  defp clear_catalog! do
    for resource <- [
          Hiraeth.Sources.SourceLedgerEntry,
          SourceRecord,
          ImportRun,
          Hiraeth.Covers.CoverAssignment,
          Hiraeth.Covers.CoverAsset,
          Hiraeth.Catalog.Identifier,
          Hiraeth.Catalog.Contribution,
          Hiraeth.Catalog.SeriesMembership,
          Hiraeth.Catalog.Edition,
          Hiraeth.Catalog.Work,
          Hiraeth.Catalog.Series,
          Hiraeth.Catalog.Imprint,
          Hiraeth.Catalog.Contributor,
          Hiraeth.Catalog.Publisher
        ] do
      Hiraeth.Repo.delete_all(resource)
    end
  end
end
