defmodule Hiraeth.RealCatalog.SourcePolicyManifestTest do
  use ExUnit.Case, async: false

  alias Hiraeth.RealCatalog.SourcePolicy

  @valid_manifest_json """
  {
    "provider": "manifest_test_publisher",
    "name": "Manifest Test Publisher",
    "source_mode": "api",
    "source_urls": [
      "https://www.manifesttest.example/books",
      "https://www.manifesttest.example/catalogs"
    ],
    "source_hosts": ["www.manifesttest.example"],
    "cover_hosts": ["cdn.manifesttest.example", "covers.openlibrary.org"],
    "api": {
      "type": "shopify"
    },
    "permission_basis": "Test manifest provider for source policy",
    "takedown_contact": "test@manifesttest.example",
    "excluded_content": ["raw_html", "prices"],
    "cover_cache_policy": "cache_allowed",
    "not_legal_advice": true
  }
  """

  setup do
    Process.delete(:manifest_providers)
    :ok
  end

  describe "load_provider_manifest/1" do
    test "loads and validates a manifest file and returns provider slug" do
      path = write_temp_manifest(@valid_manifest_json)

      assert {:ok, "manifest_test_publisher"} = SourcePolicy.load_provider_manifest(path)
    after
      cleanup_temp_manifests()
    end

    test "raises on invalid manifest" do
      bad_json = ~s({"provider": "bad"})
      path = write_temp_manifest(bad_json)

      assert_raise RuntimeError, ~r/manifest validation failed/, fn ->
        SourcePolicy.load_provider_manifest(path)
      end
    after
      cleanup_temp_manifests()
    end
  end

  describe "manifest-loaded provider host checks" do
    setup do
      path = write_temp_manifest(@valid_manifest_json)
      SourcePolicy.load_provider_manifest(path)
      :ok
    end

    test "source_host_allowed? returns true for manifest source hosts" do
      assert SourcePolicy.source_host_allowed?(
               "manifest_test_publisher",
               "www.manifesttest.example"
             )
    end

    test "source_host_allowed? returns false for unknown hosts" do
      refute SourcePolicy.source_host_allowed?("manifest_test_publisher", "evil.example")
    end

    test "cover_host_allowed? returns true for manifest cover hosts" do
      assert SourcePolicy.cover_host_allowed?(
               "manifest_test_publisher",
               "cdn.manifesttest.example"
             )

      assert SourcePolicy.cover_host_allowed?(
               "manifest_test_publisher",
               "covers.openlibrary.org"
             )
    end

    test "cover_host_allowed? returns false for unknown hosts" do
      refute SourcePolicy.cover_host_allowed?("manifest_test_publisher", "evil.example")
    end

    test "source_uri_allowed? returns true for manifest source URLs" do
      assert SourcePolicy.source_uri_allowed?(
               "manifest_test_publisher",
               "https://www.manifesttest.example/books"
             )

      assert SourcePolicy.source_uri_allowed?(
               "manifest_test_publisher",
               "https://www.manifesttest.example/books/a-book"
             )

      assert SourcePolicy.source_uri_allowed?(
               "manifest_test_publisher",
               "https://www.manifesttest.example/catalogs"
             )

      assert SourcePolicy.source_uri_allowed?(
               "manifest_test_publisher",
               "https://www.manifesttest.example/catalogs/spring-2024"
             )
    end

    test "source_uri_allowed? returns false for non-HTTPS or off-host URLs" do
      refute SourcePolicy.source_uri_allowed?(
               "manifest_test_publisher",
               "http://www.manifesttest.example/books"
             )

      refute SourcePolicy.source_uri_allowed?(
               "manifest_test_publisher",
               "https://evil.example/books"
             )
    end

    test "source_uri_allowed? returns false for paths outside allowed prefixes" do
      refute SourcePolicy.source_uri_allowed?(
               "manifest_test_publisher",
               "https://www.manifesttest.example/admin"
             )

      refute SourcePolicy.source_uri_allowed?(
               "manifest_test_publisher",
               "https://www.manifesttest.example/"
             )
    end

    test "cover_uri_allowed? returns true for manifest cover URLs" do
      assert SourcePolicy.cover_uri_allowed?(
               "manifest_test_publisher",
               "https://cdn.manifesttest.example/cover.jpg"
             )
    end

    test "purchase_uri_allowed? delegates to source_uri_allowed?" do
      assert SourcePolicy.purchase_uri_allowed?(
               "manifest_test_publisher",
               "https://www.manifesttest.example/books/a-book"
             )
    end

    # {insert}
  end

  describe "hardcoded providers still work alongside manifest providers" do
    test "existing hardcoded provider source hosts are still allowed" do
      assert SourcePolicy.source_host_allowed?("new_directions_official_site", "www.ndbooks.com")

      assert SourcePolicy.source_host_allowed?(
               "transit_books_official_site",
               "www.transitbooks.org"
             )
    end

    test "existing hardcoded provider cover hosts are still allowed" do
      assert SourcePolicy.cover_host_allowed?("new_directions_official_site", "cdn.sanity.io")

      assert SourcePolicy.cover_host_allowed?(
               "transit_books_official_site",
               "images.squarespace-cdn.com"
             )
    end

    test "existing hardcoded provider source URIs are still allowed" do
      assert SourcePolicy.source_uri_allowed?(
               "new_directions_official_site",
               "https://www.ndbooks.com/books/a-book/"
             )

      assert SourcePolicy.source_uri_allowed?(
               "transit_books_official_site",
               "https://www.transitbooks.org/books/a-shining"
             )
    end

    test "unknown provider returns false for host checks" do
      refute SourcePolicy.source_host_allowed?("totally_unknown_provider", "any.host")
      refute SourcePolicy.cover_host_allowed?("totally_unknown_provider", "any.host")
    end

    test "unknown provider source_uri_allowed? returns false" do
      refute SourcePolicy.source_uri_allowed?(
               "totally_unknown_provider",
               "https://any.host/path"
             )
    end
  end

  describe "Deep Vellum manifest handle patterns" do
    @deep_vellum_manifest "priv/catalog_sources/provider_manifests/deep_vellum_official_store.json"
    @new_deep_vellum_handle_url "https://store.deepvellum.org/products/manic-pixie-american-dream-patterson-bleah"

    test "new product handle is rejected by the manifest without pattern and accepted after pattern load" do
      no_pattern_manifest =
        @deep_vellum_manifest
        |> File.read!()
        |> Jason.decode!()
        |> update_in(["api"], &Map.delete(&1, "source_handle_patterns"))
        |> Jason.encode!()
        |> write_temp_manifest()

      assert {:ok, "deep_vellum_official_store"} =
               SourcePolicy.load_provider_manifest(no_pattern_manifest)

      refute SourcePolicy.source_uri_allowed?(
               "deep_vellum_official_store",
               @new_deep_vellum_handle_url
             )

      Process.delete(:manifest_providers)

      assert {:ok, "deep_vellum_official_store"} =
               SourcePolicy.load_provider_manifest(@deep_vellum_manifest)

      refute SourcePolicy.source_uri_allowed?(
               "deep_vellum_official_store",
               @new_deep_vellum_handle_url
             )

      assert SourcePolicy.source_uri_allowed?(
               "deep_vellum_official_store",
               @new_deep_vellum_handle_url,
               %{publisher: "Deep Vellum"}
             )

      assert SourcePolicy.source_uri_allowed?(
               "deep_vellum_official_store",
               @new_deep_vellum_handle_url <> "#paperback",
               %{publisher: "Deep Vellum Publishing"}
             )

      refute SourcePolicy.source_uri_allowed?(
               "deep_vellum_official_store",
               "https://store.deepvellum.org/products/phoneme-book",
               %{publisher: "Phoneme"}
             )
    after
      cleanup_temp_manifests()
    end

    test "handle pattern rejects unknown providers, off-host URLs, and encoded traversal" do
      assert {:ok, "deep_vellum_official_store"} =
               SourcePolicy.load_provider_manifest(@deep_vellum_manifest)

      refute SourcePolicy.source_uri_allowed?(
               "totally_unknown_provider",
               @new_deep_vellum_handle_url
             )

      refute SourcePolicy.source_uri_allowed?(
               "deep_vellum_official_store",
               "https://evil.example/products/manic-pixie-american-dream-patterson-bleah"
             )

      refute SourcePolicy.source_uri_allowed?(
               "deep_vellum_official_store",
               "https://store.deepvellum.org/products/%2e%2e/admin"
             )

      refute SourcePolicy.source_uri_allowed?(
               "deep_vellum_official_store",
               "https://store.deepvellum.org/products/manic-pixie-american-dream-patterson-bleah?cart=true"
             )

      refute SourcePolicy.source_uri_allowed?("deep_vellum_official_store", nil)
      refute SourcePolicy.source_uri_allowed?("deep_vellum_official_store", "")
      refute SourcePolicy.source_uri_allowed?("deep_vellum_official_store", "not a uri")
    end
  end

  # --- Helpers ---

  defp write_temp_manifest(json) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hiraeth_manifest_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "manifest.json")
    File.write!(path, json)
    path
  end

  defp cleanup_temp_manifests do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "hiraeth_manifest_test_"))
    |> Enum.each(fn dir ->
      File.rm_rf!(Path.join(System.tmp_dir!(), dir))
    end)
  end
end
