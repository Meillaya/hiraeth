defmodule Hiraeth.Ingestion.ManifestValidatorTest do
  use ExUnit.Case, async: true

  alias Hiraeth.Ingestion.ManifestValidator

  @fixtures_dir Path.expand("../../support/fixtures/provider_manifests", __DIR__)

  # Helper: read and atomize a fixture
  defp load_fixture(filename) do
    @fixtures_dir
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
    |> atomize()
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {String.to_atom(key), atomize(value)} end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  describe "validate/1 with valid manifests" do
    test "accepts a valid API-mode manifest" do
      manifest = load_fixture("valid_api_manifest.json")
      assert {:ok, _manifest} = ManifestValidator.validate(manifest)
    end

    test "accepts a valid scrape-mode manifest" do
      manifest = load_fixture("valid_scrape_manifest.json")
      assert {:ok, _manifest} = ManifestValidator.validate(manifest)
    end
  end

  describe "validate/1 with missing required fields" do
    test "rejects manifest missing all required fields" do
      manifest = load_fixture("invalid_missing_fields.json")
      assert {:error, findings} = ManifestValidator.validate(manifest)
      assert length(findings) > 0

      reasons = Enum.map(findings, & &1.reason)
      assert Enum.any?(reasons, &String.contains?(&1, "source_mode is required"))
      assert Enum.any?(reasons, &String.contains?(&1, "source_urls is required"))
      assert Enum.any?(reasons, &String.contains?(&1, "source_hosts is required"))
      assert Enum.any?(reasons, &String.contains?(&1, "cover_hosts is required"))
      assert Enum.any?(reasons, &String.contains?(&1, "permission_basis is required"))
      assert Enum.any?(reasons, &String.contains?(&1, "takedown_contact is required"))
      assert Enum.any?(reasons, &String.contains?(&1, "excluded_content is required"))
      assert Enum.any?(reasons, &String.contains?(&1, "cover_cache_policy is required"))
      assert Enum.any?(reasons, &String.contains?(&1, "not_legal_advice is required"))
    end
  end

  describe "validate/1 with invalid source_mode" do
    test "rejects source_mode that is not api or scrape" do
      manifest = load_fixture("invalid_source_mode.json")
      assert {:error, findings} = ManifestValidator.validate(manifest)

      reasons = Enum.map(findings, & &1.reason)
      assert Enum.any?(reasons, &String.contains?(&1, "source_mode must be"))
    end
  end

  describe "validate/1 with non-HTTPS source URLs" do
    test "rejects manifest with http:// source URL" do
      manifest = load_fixture("invalid_non_https_url.json")
      assert {:error, findings} = ManifestValidator.validate(manifest)

      reasons = Enum.map(findings, & &1.reason)
      assert Enum.any?(reasons, &String.contains?(&1, "must be HTTPS"))
    end
  end

  describe "validate/1 with missing api.type for api mode" do
    test "rejects api-mode manifest without api.type" do
      manifest = load_fixture("invalid_api_no_type.json")
      assert {:error, findings} = ManifestValidator.validate(manifest)

      reasons = Enum.map(findings, & &1.reason)
      assert Enum.any?(reasons, &String.contains?(&1, "api.type is required"))
    end
  end

  describe "validate/1 with missing spider.module for scrape mode" do
    test "rejects scrape-mode manifest without spider.module" do
      manifest = load_fixture("invalid_scrape_no_module.json")
      assert {:error, findings} = ManifestValidator.validate(manifest)

      reasons = Enum.map(findings, & &1.reason)
      assert Enum.any?(reasons, &String.contains?(&1, "spider.module is required"))
    end
  end

  describe "validate/1 with invalid expected_record_count" do
    test "rejects expected_record_count of 0" do
      manifest = load_fixture("invalid_record_count.json")
      assert {:error, findings} = ManifestValidator.validate(manifest)

      reasons = Enum.map(findings, & &1.reason)

      assert Enum.any?(
               reasons,
               &String.contains?(&1, "expected_record_count must be a positive integer")
             )
    end
  end

  describe "validate/1 with invalid api.type value" do
    test "rejects api.type that is not in the allowed set" do
      manifest = %{
        provider: "test_bad_api_type",
        name: "Test Bad API Type",
        source_mode: "api",
        source_urls: ["https://www.example.com"],
        source_hosts: ["www.example.com"],
        cover_hosts: ["cdn.example.com"],
        api: %{type: "magento"},
        permission_basis: "Test.",
        takedown_contact: "test@example.com",
        excluded_content: ["raw_html"],
        cover_cache_policy: "cache_allowed",
        not_legal_advice: true
      }

      assert {:error, findings} = ManifestValidator.validate(manifest)

      reasons = Enum.map(findings, & &1.reason)
      assert Enum.any?(reasons, &String.contains?(&1, "api.type must be one of"))
    end
  end

  describe "validate/1 with unsafe api.endpoint values" do
    test "rejects API endpoint hosts outside source_hosts" do
      manifest =
        valid_api_manifest(%{
          api: %{type: "shopify", endpoint: "https://evil.example.com"},
          source_hosts: ["www.example.com"]
        })

      assert {:error, findings} = ManifestValidator.validate(manifest)

      assert findings
             |> Enum.map(& &1.reason)
             |> Enum.any?(
               &String.contains?(&1, "api.endpoint host must be listed in source_hosts")
             )
    end

    test "rejects private API endpoint hosts even when source_hosts includes them" do
      manifest =
        valid_api_manifest(%{
          api: %{type: "shopify", endpoint: "https://127.0.0.1"},
          source_hosts: ["127.0.0.1"]
        })

      assert {:error, findings} = ManifestValidator.validate(manifest)

      assert findings
             |> Enum.map(& &1.reason)
             |> Enum.any?(&String.contains?(&1, "api.endpoint host must not be private"))
    end

    test "rejects private IPv6 API endpoint hosts" do
      manifest =
        valid_api_manifest(%{
          api: %{type: "shopify", endpoint: "https://[fd12::1]"},
          source_hosts: ["fd12::1"]
        })

      assert {:error, findings} = ManifestValidator.validate(manifest)

      assert findings
             |> Enum.map(& &1.reason)
             |> Enum.any?(&String.contains?(&1, "api.endpoint host must not be private"))
    end

    test "rejects API endpoints with userinfo" do
      manifest =
        valid_api_manifest(%{
          api: %{type: "shopify", endpoint: "https://user:pass@www.example.com"},
          source_hosts: ["www.example.com"]
        })

      assert {:error, findings} = ManifestValidator.validate(manifest)

      assert findings
             |> Enum.map(& &1.reason)
             |> Enum.any?(&String.contains?(&1, "api.endpoint must not include userinfo"))
    end
  end

  describe "validate/1 with non-integer expected_record_count" do
    test "rejects string expected_record_count" do
      manifest = load_fixture("invalid_record_count_string.json")
      assert {:error, findings} = ManifestValidator.validate(manifest)

      reasons = Enum.map(findings, & &1.reason)

      assert Enum.any?(
               reasons,
               &String.contains?(&1, "expected_record_count must be a positive integer")
             )
    end
  end

  describe "validate/1 with missing provider slug" do
    test "rejects manifest without provider slug" do
      manifest = load_fixture("invalid_missing_provider.json")
      assert {:error, findings} = ManifestValidator.validate(manifest)

      reasons = Enum.map(findings, & &1.reason)
      assert Enum.any?(reasons, &String.contains?(&1, "provider is required"))
    end
  end

  describe "validate/1 with missing source_mode" do
    test "rejects manifest without source_mode when neither spider nor api config is present" do
      manifest = load_fixture("invalid_missing_source_mode.json")
      assert {:error, findings} = ManifestValidator.validate(manifest)

      reasons = Enum.map(findings, & &1.reason)
      assert Enum.any?(reasons, &String.contains?(&1, "source_mode is required"))
    end

    test "accepts manifest with api config and no explicit source_mode" do
      manifest =
        load_fixture("invalid_missing_source_mode.json")
        |> put_in([:api], %{
          type: "shopify",
          endpoint: "https://www.testpublisher.com/api/graphql"
        })

      assert {:ok, _manifest} = ManifestValidator.validate(manifest)
    end

    test "accepts manifest with spider config and no explicit source_mode" do
      manifest =
        load_fixture("invalid_missing_source_mode.json")
        |> put_in([:spider], %{
          module: "Hiraeth.Ingestion.Spiders.TestScraper",
          start_urls: ["https://www.testpublisher.com/books"]
        })

      assert {:ok, _manifest} = ManifestValidator.validate(manifest)
    end
  end

  describe "validate/1 with missing cover_hosts" do
    test "rejects manifest without cover_hosts" do
      manifest = load_fixture("invalid_missing_cover_hosts.json")
      assert {:error, findings} = ManifestValidator.validate(manifest)

      reasons = Enum.map(findings, & &1.reason)
      assert Enum.any?(reasons, &String.contains?(&1, "cover_hosts is required"))
    end
  end

  describe "validate/1 with missing permission_basis" do
    test "rejects manifest without permission_basis" do
      manifest = load_fixture("invalid_missing_permission_basis.json")
      assert {:error, findings} = ManifestValidator.validate(manifest)

      reasons = Enum.map(findings, & &1.reason)
      assert Enum.any?(reasons, &String.contains?(&1, "permission_basis is required"))
    end
  end

  describe "real publisher ingestion manifests" do
    @real_manifest_dir Path.expand("../../../priv/catalog_sources/provider_manifests", __DIR__)
    @new_provider_expectations %{
      "two_lines_press_official_store" => %{
        mode: "api",
        cover_host: "www.twolinespress.com",
        count: 83
      },
      "wakefield_press_official_store" => %{
        mode: "api",
        cover_host: "cdn.shopify.com",
        count: 104
      },
      "astra_house_official_store" => %{
        mode: "scrape",
        cover_host: "images.penguinrandomhouse.com",
        count: 53
      },
      "sandorf_passage_official_store" => %{
        mode: "api",
        cover_host: "sandorfpassage.org",
        count: 32
      },
      "seagull_books_official_store" => %{
        mode: "api",
        cover_host: "cdn.shopify.com",
        count: 822
      },
      "pushkin_press_us_official_store" => %{
        mode: "api",
        cover_host: "us.pushkinpress.com",
        count: 267
      }
    }

    for {provider, expectation} <- @new_provider_expectations do
      @provider provider
      @expectation expectation

      test "accepts #{@provider} manifest with expected source and cover policy" do
        manifest =
          @real_manifest_dir
          |> Path.join("#{@provider}.json")
          |> File.read!()
          |> Jason.decode!()
          |> atomize()

        assert {:ok, validated} = ManifestValidator.validate(manifest)
        assert validated.provider == @provider
        assert validated.source_mode == @expectation.mode
        assert @expectation.cover_host in validated.cover_hosts
        assert validated.expected_record_count == @expectation.count
        assert "cart_checkout_account" in validated.excluded_content
      end
    end
  end

  defp valid_api_manifest(overrides) do
    %{
      provider: "test_api_endpoint",
      name: "Test API Endpoint",
      source_mode: "api",
      source_urls: ["https://www.example.com"],
      source_hosts: ["www.example.com"],
      cover_hosts: ["cdn.example.com"],
      api: %{type: "shopify", endpoint: "https://www.example.com"},
      permission_basis: "Test.",
      takedown_contact: "test@example.com",
      excluded_content: ["raw_html"],
      cover_cache_policy: "cache_allowed",
      not_legal_advice: true
    }
    |> Map.merge(overrides)
  end
end
