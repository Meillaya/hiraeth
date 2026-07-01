defmodule Hiraeth.Ingestion.MixTaskDryRunTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Ingestion.{ProviderRun, ProviderSource}

  @valid_manifest Path.join([
                    File.cwd!(),
                    "test/support/fixtures/provider_manifests/valid_api_manifest.json"
                  ])

  @implicit_scrape_manifest Path.join([
                              File.cwd!(),
                              "test/support/fixtures/provider_manifests/implicit_scrape_manifest.json"
                            ])

  @deep_vellum_manifest Path.join([
                          File.cwd!(),
                          "priv/catalog_sources/provider_manifests/deep_vellum_official_store.json"
                        ])

  alias Hiraeth.TestSupport.MixTaskMocks.{
    MockConfigCaptureSidecarClient,
    MockCoverPipeline,
    MockImporter,
    MockSidecarClient
  }

  setup do
    Application.put_env(:hiraeth, :sidecar_client, MockSidecarClient)
    Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
    Application.put_env(:hiraeth, :importer, MockImporter)

    on_exit(fn ->
      Application.delete_env(:hiraeth, :sidecar_client)
      Application.delete_env(:hiraeth, :cover_pipeline)
      Application.delete_env(:hiraeth, :importer)
    end)

    :ok
  end

  describe "dry-run mode selection" do
    test "manifest with spider config and no source_mode uses scrape mode" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.Ingest.do_run([
                     "--provider",
                     "test_publisher_scrape_implicit",
                     "--manifest",
                     @implicit_scrape_manifest,
                     "--dry-run"
                   ])
        end)

      assert output =~ "effective_source_mode=scrape"
      assert output =~ "first_record_title=Test Scraped Book"
    end

    test "dry-run json prints provider run plan without mutating provider run tables" do
      before_sources = count_resource(ProviderSource)
      before_runs = count_resource(ProviderRun)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.Ingest.do_run([
                     "--provider",
                     "test_publisher_api",
                     "--manifest",
                     @valid_manifest,
                     "--dry-run",
                     "--json"
                   ])
        end)

      assert count_resource(ProviderSource) == before_sources
      assert count_resource(ProviderRun) == before_runs

      assert %{"dry_run" => true, "provider" => "test_publisher_api", "run" => run} =
               Jason.decode!(output)

      assert run["status"] == "planned"
      assert run["requested_by"] == "mix hiraeth.ingest"
      assert run["run_key"] =~ "dry-run:test_publisher_api:"
      assert run["would_create_provider_run"] == true

      assert run["phases"] == [
               "fetch_snapshot",
               "normalize_candidates",
               "validate_candidates",
               "diff_candidates",
               "cover_candidates",
               "quarantine_run",
               "apply_candidates",
               "audit_run"
             ]
    end

    test "manifest with source_mode: api uses api mode" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.Ingest.do_run([
                     "--provider",
                     "test_publisher_api",
                     "--manifest",
                     @valid_manifest,
                     "--dry-run"
                   ])
        end)

      assert output =~ "effective_source_mode=api"
      assert output =~ "first_record_title=Test Book Title"
      assert output =~ "Dry-run validation passed"
    end

    test "dry-run forwards provider-specific api manifest keys to the sidecar" do
      manifest_path =
        @valid_manifest
        |> File.read!()
        |> Jason.decode!()
        |> put_in(["api", "collection_path"], "/collections/all-books-in-print")
        |> put_in(["api", "vendor_as_author"], false)
        |> put_in(["api", "post_type"], "book")
        |> put_in(["api", "include_imprints"], ["pushkin-press"])
        |> write_temp_manifest()

      Application.put_env(:hiraeth, :sidecar_client, MockConfigCaptureSidecarClient)
      Process.put(:capture_pid, self())

      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok =
                 Mix.Tasks.Hiraeth.Ingest.do_run([
                   "--provider",
                   "test_publisher_api",
                   "--manifest",
                   manifest_path,
                   "--dry-run"
                 ])
      end)

      assert_receive {:fetch_provider_config, %{config: %{api: api}}}
      assert api[:collection_path] == "/collections/all-books-in-print"
      assert api[:vendor_as_author] == false
      assert api[:post_type] == "book"
      assert api[:include_imprints] == ["pushkin-press"]
    after
      Process.delete(:capture_pid)
      cleanup_temp_manifests()
    end

    test "dry-run reports expected_record_count mismatch without persisting" do
      manifest_path =
        @valid_manifest
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("expected_record_count", 2)
        |> write_temp_manifest()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.Ingest.do_run([
                     "--provider",
                     "test_publisher_api",
                     "--manifest",
                     manifest_path,
                     "--dry-run"
                   ])
        end)

      assert output =~ "expected_record_count 2 does not match fetched record count 1"
      assert output =~ "Dry-run completed with validation issues"
    after
      cleanup_temp_manifests()
    end

    test "dry-run prints effective_source_mode=scrape for Deep Vellum manifest" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.Ingest.do_run([
                     "--provider",
                     "deep_vellum_official_store",
                     "--manifest",
                     @deep_vellum_manifest,
                     "--dry-run"
                   ])
        end)

      assert output =~ "effective_source_mode=scrape"
    end
  end

  defp write_temp_manifest(manifest) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hiraeth_mix_task_manifest_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "manifest.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end

  defp count_resource(resource) do
    resource
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp cleanup_temp_manifests do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "hiraeth_mix_task_manifest_test_"))
    |> Enum.each(fn dir ->
      File.rm_rf!(Path.join(System.tmp_dir!(), dir))
    end)
  end
end
