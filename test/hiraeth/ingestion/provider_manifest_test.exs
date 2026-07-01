defmodule Hiraeth.Ingestion.ProviderManifestTest do
  use ExUnit.Case, async: true

  alias Hiraeth.Ingestion.OperatorManifest
  alias Hiraeth.Ingestion.ProviderManifest

  @fixtures_dir Path.expand("../../support/fixtures/provider_manifests", __DIR__)

  describe "load!/1 with valid manifests" do
    test "loads a valid API-mode manifest" do
      manifest =
        ProviderManifest.load!(Path.join(@fixtures_dir, "valid_api_manifest.json"))

      assert %ProviderManifest{} = manifest
      assert manifest.provider == "test_publisher_api"
      assert manifest.name == "Test Publisher (API)"
      assert manifest.source_mode == "api"
      assert manifest.source_urls == ["https://www.testpublisher.com/books"]
      assert manifest.source_hosts == ["www.testpublisher.com"]
      assert manifest.cover_hosts == ["cdn.testpublisher.com"]

      assert manifest.api == %{
               type: "shopify",
               endpoint: "https://www.testpublisher.com/api/graphql",
               auth: %{method: "api_key", key_env: "TEST_PUBLISHER_API_KEY"}
             }

      assert manifest.rate_limit == %{
               max_concurrency: 2,
               min_delay_ms: 500,
               max_bytes: 10_485_760
             }

      assert manifest.expected_record_count == 1
      assert manifest.permission_basis =~ "Official publisher pages"
      assert manifest.takedown_contact == "contact@testpublisher.com"
      assert manifest.excluded_content == ["raw_html", "prices", "reviews"]
      assert manifest.cover_cache_policy == "cache_allowed"
      assert manifest.not_legal_advice == true
    end

    test "loads a valid scrape-mode manifest" do
      manifest =
        ProviderManifest.load!(Path.join(@fixtures_dir, "valid_scrape_manifest.json"))

      assert %ProviderManifest{} = manifest
      assert manifest.provider == "test_publisher_scrape"
      assert manifest.source_mode == "scrape"

      assert manifest.spider == %{
               module: "Hiraeth.Ingestion.Spiders.TestScraper",
               start_urls: ["https://www.testscraper.com/catalog"],
               selectors: %{
                 book: ".book-item",
                 title: ".book-title",
                 author: ".book-author"
               }
             }

      assert manifest.expected_record_count == 1

      assert manifest.rate_limit == %{
               max_concurrency: 1,
               min_delay_ms: 1000,
               max_bytes: 5_242_880
             }
    end
  end

  describe "effective_source_mode/1" do
    test "returns scrape when spider config is present and source_mode is absent" do
      manifest = %{
        provider: "test_spider_only",
        spider: %{
          module: "Hiraeth.Ingestion.Spiders.TestScraper",
          start_urls: ["https://www.testscraper.com/catalog"]
        }
      }

      assert ProviderManifest.effective_source_mode(manifest) == "scrape"
    end

    test "returns api when source_mode is explicit api even if spider config exists" do
      manifest = %{
        provider: "test_api_override",
        source_mode: "api",
        spider: %{
          module: "Hiraeth.Ingestion.Spiders.TestScraper",
          start_urls: ["https://www.testscraper.com/catalog"]
        },
        api: %{type: "shopify", endpoint: "https://www.example.com"}
      }

      assert ProviderManifest.effective_source_mode(manifest) == "api"
    end

    test "returns api when only api config is present and source_mode is absent" do
      manifest = %{
        provider: "test_api_only",
        api: %{type: "shopify", endpoint: "https://www.example.com"}
      }

      assert ProviderManifest.effective_source_mode(manifest) == "api"
    end

    test "returns error when source_mode is absent and no config is present" do
      manifest = %{provider: "test_no_mode"}

      assert ProviderManifest.effective_source_mode(manifest) ==
               {:error, "source_mode is required"}
    end
  end

  describe "load!/1 with invalid manifests" do
    test "raises on missing required fields" do
      assert_raise RuntimeError, ~r/manifest validation failed/, fn ->
        ProviderManifest.load!(Path.join(@fixtures_dir, "invalid_missing_fields.json"))
      end
    end

    test "raises on invalid source_mode" do
      assert_raise RuntimeError, ~r/source_mode must be/, fn ->
        ProviderManifest.load!(Path.join(@fixtures_dir, "invalid_source_mode.json"))
      end
    end

    test "raises on non-HTTPS source URLs" do
      assert_raise RuntimeError, ~r/must be HTTPS/, fn ->
        ProviderManifest.load!(Path.join(@fixtures_dir, "invalid_non_https_url.json"))
      end
    end

    test "raises when api.type is missing for api mode" do
      assert_raise RuntimeError, ~r/api.type is required/, fn ->
        ProviderManifest.load!(Path.join(@fixtures_dir, "invalid_api_no_type.json"))
      end
    end

    test "raises when spider.module is missing for scrape mode" do
      assert_raise RuntimeError, ~r/spider.module is required/, fn ->
        ProviderManifest.load!(Path.join(@fixtures_dir, "invalid_scrape_no_module.json"))
      end
    end

    test "raises on non-positive expected_record_count" do
      assert_raise RuntimeError, ~r/expected_record_count must be a positive integer/, fn ->
        ProviderManifest.load!(Path.join(@fixtures_dir, "invalid_record_count.json"))
      end
    end

    test "raises on non-existent file" do
      assert_raise File.Error, fn ->
        ProviderManifest.load!(Path.join(@fixtures_dir, "nonexistent.json"))
      end
    end

    test "does not reflect secret-bearing source URLs in raised validation errors" do
      secret_url = secret_source_url()
      path = write_temp_manifest(secret_manifest(secret_url))

      error =
        assert_raise RuntimeError, fn ->
          ProviderManifest.load!(path)
        end

      assert Exception.message(error) =~ "source_url must not include userinfo"
      refute_secret_reflection(Exception.message(error), secret_url)
    after
      cleanup_temp_manifests()
    end
  end

  describe "OperatorManifest.load/1 with invalid manifests" do
    test "does not reflect secret-bearing source URLs in returned load errors" do
      secret_url = secret_source_url()
      path = write_temp_manifest(secret_manifest(secret_url))

      assert {:error, message} = OperatorManifest.load(path)
      assert message =~ "source_url must not include userinfo"
      refute_secret_reflection(message, secret_url)
    after
      cleanup_temp_manifests()
    end
  end

  defp secret_manifest(secret_url) do
    %{
      provider: "secret_reflection_test",
      name: "Secret Reflection Test",
      source_mode: "api",
      source_urls: [secret_url],
      source_hosts: ["www.example.com"],
      cover_hosts: ["cdn.example.com"],
      api: %{type: "shopify", endpoint: "https://www.example.com"},
      permission_basis: "Official publisher pages expose public catalog facts.",
      takedown_contact: "security@example.com",
      excluded_content: ["raw_html"],
      cover_cache_policy: "cache_allowed",
      not_legal_advice: true
    }
  end

  defp secret_source_url do
    "http://user:GLOBAL_REPAIR4_PASSWORD@evil.example.com/books?token=GLOBAL_REPAIR4_QUERY#GLOBAL_REPAIR4_FRAGMENT"
  end

  defp write_temp_manifest(manifest) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hiraeth_provider_manifest_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "manifest.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end

  defp cleanup_temp_manifests do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "hiraeth_provider_manifest_test_"))
    |> Enum.each(fn dir ->
      File.rm_rf!(Path.join(System.tmp_dir!(), dir))
    end)
  end

  defp refute_secret_reflection(message, full_url) do
    refute message =~ full_url
    refute message =~ "user:GLOBAL_REPAIR4_PASSWORD"
    refute message =~ "GLOBAL_REPAIR4_PASSWORD"
    refute message =~ "GLOBAL_REPAIR4_QUERY"
    refute message =~ "GLOBAL_REPAIR4_FRAGMENT"
    refute message =~ "?token="
    refute message =~ "#GLOBAL"
  end
end
