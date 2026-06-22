defmodule Hiraeth.Ingestion.E2EIngestionStealthyTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Catalog.{
    Contribution,
    Contributor,
    Edition,
    Identifier,
    Imprint,
    Publisher,
    Series,
    SeriesMembership,
    Work
  }

  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}
  alias Hiraeth.Support.DeepVellumStealthyFixture
  alias Hiraeth.Support.MockDeepVellumStealthySidecarClient

  require Ash.Query

  @provider DeepVellumStealthyFixture.provider()
  @manifest_path Path.join([
                   File.cwd!(),
                   "priv/catalog_sources/provider_manifests/deep_vellum_official_store.json"
                 ])

  setup do
    clear_catalog!()

    Application.put_env(:hiraeth, :sidecar_client, MockDeepVellumStealthySidecarClient)

    staged_path = staged_path()
    current_path = current_path()
    original_current = read_if_exists(current_path)
    original_staged = read_if_exists(staged_path)

    File.rm(staged_path)

    on_exit(fn ->
      Application.delete_env(:hiraeth, :sidecar_client)
      restore_file!(current_path, original_current)
      restore_file!(staged_path, original_staged)
      clear_catalog!()
    end)

    :ok
  end

  @tag timeout: 120_000
  test "deterministic Deep Vellum stealthy scrape reviews clean and applies" do
    DeepVellumStealthyFixture.write_dataset!(current_path(), DeepVellumStealthyFixture.records())

    scrape_output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok =
                 Mix.Tasks.Hiraeth.Scrape.run([
                   "--provider",
                   @provider,
                   "--manifest",
                   @manifest_path
                 ])
      end)

    assert scrape_output =~ "Staged dataset for provider: #{@provider}"
    assert scrape_output =~ "records=2"
    assert File.exists?(staged_path())

    review_output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Mix.Tasks.Hiraeth.ReviewScrape.run(["--provider", @provider])
      end)

    assert review_output =~ "staged=2 current=2 new=0 missing=0 changed=0"
    assert review_output =~ "validation_findings=0"
    assert review_output =~ "No differences found"

    apply_output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Mix.Tasks.Hiraeth.ApplyScrape.run(["--provider", @provider])
      end)

    assert apply_output =~ "Applied staged dataset for provider: #{@provider}"
    assert apply_output =~ "records_imported=2"
    assert apply_output =~ "source_records_created=2"
    refute File.exists?(staged_path())

    source_records =
      SourceRecord
      |> Ash.Query.filter(provider: @provider, source_type: "publisher_dataset")
      |> Ash.read!(authorize?: false)

    assert length(source_records) == 2
    assert Ash.read!(Edition, authorize?: false) |> length() == 2
    assert Ash.read!(Contribution, authorize?: false) |> length() == 3
    assert Ash.read!(CoverAsset, authorize?: false) |> length() == 2
    assert Ash.read!(CoverAssignment, authorize?: false) |> length() == 2
  end

  test "review reports a staged Deep Vellum record with missing contributors" do
    [valid_record | _] = DeepVellumStealthyFixture.records()
    invalid_record = DeepVellumStealthyFixture.missing_contributors_record(valid_record)

    DeepVellumStealthyFixture.write_dataset!(current_path(), [valid_record])
    DeepVellumStealthyFixture.write_dataset!(staged_path(), [invalid_record])

    review_output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Mix.Tasks.Hiraeth.ReviewScrape.run(["--provider", @provider])
      end)

    assert review_output =~ "staged=1 current=1 new=0 missing=0 changed=1"
    assert review_output =~ "validation_findings=1"
    assert review_output =~ "at least one contributor is required"
  end

  defp staged_path do
    Application.app_dir(:hiraeth, "priv/catalog_sources/staged/#{@provider}.json")
  end

  defp current_path do
    Application.app_dir(:hiraeth, "priv/catalog_sources/real_publishers/#{@provider}.json")
  end

  defp read_if_exists(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> :missing
    end
  end

  defp restore_file!(path, {:ok, content}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp restore_file!(path, :missing), do: File.rm(path)

  defp clear_catalog! do
    for resource <- [
          SourceLedgerEntry,
          SourceRecord,
          ImportRun,
          CoverAssignment,
          CoverAsset,
          Identifier,
          Contribution,
          SeriesMembership,
          Edition,
          Work,
          Series,
          Imprint,
          Contributor,
          Publisher
        ] do
      Hiraeth.Repo.delete_all(resource)
    end
  end
end
