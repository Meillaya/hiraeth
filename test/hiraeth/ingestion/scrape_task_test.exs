defmodule Hiraeth.Ingestion.ScrapeTaskTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.RealCatalog.Dataset

  @valid_scrape_manifest Path.join([
                           File.cwd!(),
                           "test/support/fixtures/provider_manifests/valid_scrape_manifest.json"
                         ])

  defmodule MockScrapeClient do
    def health(_opts \\ []) do
      {:ok, %{status: "ok", scrapling: true}}
    end

    def scrape(_provider_config, _opts \\ []) do
      {:ok, %{records: [scrape_record()]}}
    end

    def scrape_record do
      %{
        source_uri: "https://www.testscraper.com/catalog/test-book",
        publisher: "Test Scraper Publisher",
        imprint: nil,
        source_product_id: "scrape-book-001",
        work: %{
          title: "Test Scraped Book",
          subtitle: nil,
          original_title: nil,
          original_language_code: nil,
          subjects: nil,
          publication_state: "published"
        },
        edition: %{
          title: "Test Scraped Book",
          subtitle: nil,
          format: "paperback",
          language_code: nil,
          page_count: nil,
          dimensions: nil,
          published_on: nil,
          isbn_13: nil
        },
        contributors: [%{name: "Test Scraper Author", role: "author"}],
        curation: %{status: "approved"},
        displayed_fields: ["title", "contributors", "publisher"],
        field_sources: %{
          "title" => %{
            "provider" => "test_publisher_scrape",
            "source_uri" => "https://www.testscraper.com/catalog/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          },
          "contributors" => %{
            "provider" => "test_publisher_scrape",
            "source_uri" => "https://www.testscraper.com/catalog/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          },
          "publisher" => %{
            "provider" => "test_publisher_scrape",
            "source_uri" => "https://www.testscraper.com/catalog/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          }
        },
        cover: %{
          source_url: "https://images.testscraper.com/covers/test-book.jpg",
          provider: "test_publisher_scrape",
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

  defmodule MockUnhealthySidecarClient do
    def health(_opts \\ []) do
      {:error, "connection refused"}
    end
  end

  setup do
    Application.put_env(:hiraeth, :sidecar_client, MockScrapeClient)

    staged_path = staged_path_for("test_publisher_scrape")
    File.rm(staged_path)

    on_exit(fn ->
      Application.delete_env(:hiraeth, :sidecar_client)
      File.rm(staged_path)
    end)

    :ok
  end

  describe "happy path" do
    test "writes a valid staged dataset JSON" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.Scrape.run([
                     "--provider",
                     "test_publisher_scrape",
                     "--manifest",
                     @valid_scrape_manifest
                   ])
        end)

      staged_path = staged_path_for("test_publisher_scrape")
      assert File.exists?(staged_path)

      assert {:ok, dataset} = Dataset.load_file(staged_path)
      assert dataset.provider == "test_publisher_scrape"
      assert length(dataset.records) == 1

      [record] = dataset.records
      assert record.source_uri == "https://www.testscraper.com/catalog/test-book"
      assert get_in(record, [:work, :title]) == "Test Scraped Book"
      assert get_in(record, [:edition, :format]) == "paperback"

      assert output =~ "Staged dataset for provider: test_publisher_scrape"
      assert output =~ "records=1"
      assert output =~ "covers=1"
      assert output =~ "staged_file=#{staged_path}"
    end
  end

  describe "argument validation" do
    test "missing --provider exits 1" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert catch_exit(Mix.Tasks.Hiraeth.Scrape.run([])) == {:shutdown, 1}
        end)

      assert output =~ "Usage: mix hiraeth.scrape"
    end
  end

  describe "sidecar health" do
    test "sidecar down exits 1 with message" do
      Application.put_env(:hiraeth, :sidecar_client, MockUnhealthySidecarClient)

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert catch_exit(
                   Mix.Tasks.Hiraeth.Scrape.run([
                     "--provider",
                     "test_publisher_scrape",
                     "--manifest",
                     @valid_scrape_manifest
                   ])
                 ) == {:shutdown, 1}
        end)

      assert output =~ "Scrapling sidecar is not running"
    end
  end

  defp staged_path_for(provider) do
    Application.app_dir(:hiraeth, "priv/catalog_sources/staged/#{provider}.json")
  end
end
