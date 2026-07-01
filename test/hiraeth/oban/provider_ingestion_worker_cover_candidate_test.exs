defmodule Hiraeth.Oban.ProviderIngestionWorkerCoverCandidateTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Ingestion.ProviderRun
  alias Hiraeth.Oban.ProviderIngestionWorker

  require Ash.Query

  @api_manifest_path Path.join([
                       File.cwd!(),
                       "test/support/fixtures/provider_manifests/valid_api_manifest.json"
                     ])

  setup do
    Application.put_env(:hiraeth, :test_pid, self())
    Application.put_env(:hiraeth, :sidecar_client, __MODULE__.TwoCoverSidecarClient)
    Application.put_env(:hiraeth, :importer, __MODULE__.MockImporter)

    on_exit(fn ->
      Application.delete_env(:hiraeth, :test_pid)
      Application.delete_env(:hiraeth, :sidecar_client)
      Application.delete_env(:hiraeth, :cover_pipeline)
      Application.delete_env(:hiraeth, :importer)
    end)

    :ok
  end

  defmodule TwoCoverSidecarClient do
    def fetch(_provider_config, _opts \\ []) do
      {:ok,
       %{
         records: [
           record("ok-book", "https://cdn.testpublisher.com/covers/ok-book.jpg"),
           record("failed-book", "https://cdn.testpublisher.com/covers/failed-book.jpg")
         ]
       }}
    end

    def scrape(_provider_config, _opts \\ []), do: {:ok, %{records: []}}

    defp provenance(slug) do
      %{
        "provider" => "test_publisher_api",
        "source_uri" => "https://www.testpublisher.com/books/#{slug}",
        "source_type" => "publisher_dataset",
        "rights_basis" => "public_domain"
      }
    end

    defp record(slug, cover_url) do
      %{
        source_uri: "https://www.testpublisher.com/books/#{slug}",
        publisher: "Test Publisher",
        imprint: nil,
        source_product_id: slug,
        work: %{
          title: "#{slug} title",
          subtitle: nil,
          original_title: nil,
          original_language_code: nil,
          subjects: nil,
          publication_state: "published"
        },
        edition: %{
          title: "#{slug} title",
          subtitle: nil,
          format: "paperback",
          language_code: nil,
          page_count: nil,
          dimensions: nil,
          published_on: nil,
          isbn_13: nil
        },
        contributors: [%{name: "Test Author", role: "author"}],
        curation: %{status: "approved"},
        displayed_fields: ["title", "contributors", "publisher"],
        field_sources: %{
          "title" => provenance(slug),
          "contributors" => provenance(slug),
          "publisher" => provenance(slug)
        },
        cover: %{
          source_url: cover_url,
          provider: "test_publisher_api",
          rights_basis: "local_cache_permitted",
          cache_policy: "cache_allowed",
          attribution_text: nil,
          attribution_url: nil
        },
        missing_fields: %{isbn_13: "not available from source"},
        series: [],
        review_links: [],
        editorial_praise: [],
        description: nil,
        synopsis: nil,
        storefront_url: nil,
        source_sku: nil
      }
    end
  end

  defmodule CandidateCoverPipeline do
    def cache_cover_candidates!(cover_candidates, provider_config) do
      send(Application.fetch_env!(:hiraeth, :test_pid), {
        :candidate_cover_cache,
        cover_candidates,
        provider_config
      })

      {:ok,
       %{
         cached: 1,
         failed: 1,
         quarantined: 1,
         failures: [
           %{
             record_candidate_id: List.last(cover_candidates).id,
             retry_state: "retryable",
             reason: "fixture cover fetch failed"
           }
         ],
         candidates: cover_candidates
       }}
    end

    def download_and_cache!(_cover_urls, _provider_config) do
      raise "autonomous provider ingestion must use candidate-level cover caching"
    end
  end

  defmodule StrictLegacyCoverPipeline do
    def cache_cover_candidates!(_cover_candidates, _provider_config) do
      raise "strict provider ingestion must not create candidate-level durable rows"
    end

    def download_and_cache!(_cover_urls, provider_config) do
      send(
        Application.fetch_env!(:hiraeth, :test_pid),
        {:strict_legacy_cover_cache, provider_config}
      )

      {:error,
       [%{source_url: "https://cdn.testpublisher.com/covers/failed-book.jpg", reason: "boom"}]}
    end
  end

  defmodule MockImporter do
    def seed_provider!(dataset, _import_run) do
      {:ok,
       %{
         publishers: 1,
         editions: length(dataset.records),
         source_records: length(dataset.records)
       }}
    end
  end

  test "autonomous provider ingestion finalizes cover-cache provider run after candidate failures" do
    Application.put_env(:hiraeth, :cover_pipeline, __MODULE__.CandidateCoverPipeline)
    manifest_path = write_manifest!(%{"expected_record_count" => 2})

    assert {:ok, summary} =
             ProviderIngestionWorker.perform(build_job(manifest_path, "test_publisher_api"))

    assert summary.provider == "test_publisher_api"

    assert_receive {:candidate_cover_cache, cover_candidates, provider_config}
    assert length(cover_candidates) == 2
    assert Enum.all?(cover_candidates, &(&1.record_type == "cover"))
    assert provider_config.strict? == false

    [run] = cover_provider_runs()
    assert run.status == "succeeded"
    assert run.candidate_count == 2
    assert run.accepted_count == 1
    assert run.rejected_count == 1
    assert run.error_count == 1
    assert run.snapshot_count == 1
  end

  test "strict cover policy uses legacy all-or-nothing path without durable candidate provider run" do
    Application.put_env(:hiraeth, :cover_pipeline, __MODULE__.StrictLegacyCoverPipeline)

    manifest_path =
      write_manifest!(%{"cover_cache_policy" => "strict", "expected_record_count" => 2})

    assert {:error, reason} =
             ProviderIngestionWorker.perform(build_job(manifest_path, "test_publisher_api"))

    assert reason =~ "cover cache failed"
    assert_receive {:strict_legacy_cover_cache, %{strict?: true}}
    assert [] = cover_provider_runs()
  end

  defp build_job(manifest_path, provider) do
    %Oban.Job{args: %{"manifest_path" => manifest_path, "provider" => provider}}
  end

  defp write_manifest!(overrides) do
    manifest =
      @api_manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(overrides)

    path =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-t16-manifest-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(manifest, pretty: true))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cover_provider_runs do
    ProviderRun
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.provenance["cover_cache"] == true))
  end
end
