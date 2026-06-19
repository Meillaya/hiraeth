defmodule Hiraeth.RealCatalogSourceArtifactsTest do
  use ExUnit.Case, async: true

  alias Hiraeth.RealCatalog.{SourceArtifacts, SourceFetcher}
  alias Hiraeth.RealCatalog.SourceFetcher.SourceError

  @dataset_dir Path.expand("../../priv/catalog_sources/real_publishers", __DIR__)
  @artifact_manifest Path.join(@dataset_dir, "source_artifacts_manifest.json")

  test "checked-in source artifact manifest is deterministic and complete" do
    assert {:ok, built} = SourceArtifacts.build_manifest(@dataset_dir)

    checked_in =
      @artifact_manifest
      |> File.read!()
      |> Jason.decode!()

    assert checked_in == built
    assert built["generated_from"] == "checked_in_real_publisher_fixtures"
    assert built["completeness_boundary"] == "approved_source_corpus"
    assert built["total_records"] == 7406
    assert length(built["artifacts"]) == 18

    for artifact <- built["artifacts"] do
      assert artifact["record_count"] == artifact["expected_record_count"]
      assert artifact["approved_count"] == artifact["record_count"]
      assert is_binary(artifact["dataset_sha256"])
      assert byte_size(artifact["dataset_sha256"]) == 64
      assert length(artifact["source_record_entries"]) == artifact["record_count"]

      for entry <- artifact["source_record_entries"] do
        assert entry["identity"] =~ ~r/^(isbn|source):/
        assert is_binary(entry["source_product_id"])
        assert is_binary(entry["source_uri"])
      end
    end
  end

  test "repeat source artifact writes produce stable bytes" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-source-artifacts-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    first = Path.join(tmp, "first.json")
    second = Path.join(tmp, "second.json")

    SourceArtifacts.write_manifest!(@dataset_dir, first)
    SourceArtifacts.write_manifest!(@dataset_dir, second)

    assert File.read!(first) == File.read!(second)
  end

  test "source fetch planning is allowlist-backed and excludes providers without machine-readable artifacts" do
    assert {:ok, planned_sources} = SourceFetcher.plan_sources(@dataset_dir)

    assert Enum.any?(planned_sources, fn source ->
             source.provider == "deep_vellum_official_store" and
               source.url == "https://store.deepvellum.org/products.json?limit=250" and
               source.source_type == "official_shopify_products_json"
           end)

    refute Enum.any?(planned_sources, &(&1.provider == "new_directions_official_site"))
    refute Enum.any?(planned_sources, &(&1.provider == "transit_books_official_site"))
    refute Enum.any?(planned_sources, &(&1.provider == "historical_materialism_official_site"))
    refute Enum.any?(planned_sources, &(&1.provider == "semiotexte_official_site"))

    assert %{source_type: "official_shopify_products_json"} =
             SourceFetcher.validate_source!(
               "deep_vellum_official_store",
               "https://store.deepvellum.org/products.json?limit=250",
               @dataset_dir
             )

    assert_raise SourceError, ~r/source URL is not allowlisted/, fn ->
      SourceFetcher.validate_source!(
        "deep_vellum_official_store",
        "https://store.deepvellum.org/products/not-a-feed",
        @dataset_dir
      )
    end

    assert_raise SourceError, ~r/not a machine-readable source artifact/, fn ->
      SourceFetcher.validate_source!(
        "new_directions_official_site",
        "https://www.ndbooks.com/books/",
        @dataset_dir
      )
    end

    assert_raise SourceError, ~r/not a machine-readable source artifact/, fn ->
      SourceFetcher.validate_source!(
        "transit_books_official_site",
        "https://www.transitbooks.org/catalogs",
        @dataset_dir
      )
    end
  end

  test "source fetch writes bounded approved responses with metadata" do
    tmp = unique_tmp_dir("source-fetch-ok")
    on_exit(fn -> File.rm_rf!(tmp) end)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"products":[]}))
    end

    metadata =
      SourceFetcher.fetch!(
        "deep_vellum_official_store",
        "https://store.deepvellum.org/products.json?limit=250",
        tmp,
        dataset_dir: @dataset_dir,
        req_options: [plug: plug],
        retrieved_at: "2026-06-18T00:00:00Z"
      )

    assert metadata["status"] == 200
    assert metadata["byte_size"] == byte_size(~s({"products":[]}))
    assert metadata["source_type"] == "official_shopify_products_json"
    assert File.read!(metadata["artifact_path"]) == ~s({"products":[]})
    assert File.exists?(metadata["artifact_path"] <> ".metadata.json")
  end

  test "source fetch rejects non-success responses before writing artifacts" do
    tmp = unique_tmp_dir("source-fetch-status")
    on_exit(fn -> File.rm_rf!(tmp) end)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, ~s({"error":"upstream"}))
    end

    assert_raise SourceError, ~r/returned HTTP 500/, fn ->
      SourceFetcher.fetch!(
        "deep_vellum_official_store",
        "https://store.deepvellum.org/products.json?limit=250",
        tmp,
        dataset_dir: @dataset_dir,
        req_options: [plug: plug]
      )
    end

    assert File.ls!(tmp) == []
  end

  test "source fetch rejects HTML responses before writing artifacts" do
    tmp = unique_tmp_dir("source-fetch-html")
    on_exit(fn -> File.rm_rf!(tmp) end)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, "<!doctype html><html><body>catalog page</body></html>")
    end

    assert_raise SourceError, ~r/HTML source responses are not approved/, fn ->
      SourceFetcher.fetch!(
        "deep_vellum_official_store",
        "https://store.deepvellum.org/products.json?limit=250",
        tmp,
        dataset_dir: @dataset_dir,
        req_options: [plug: plug]
      )
    end

    assert File.ls!(tmp) == []
  end

  test "source fetch enforces max bytes and fails closed when cap is zero or missing" do
    tmp = unique_tmp_dir("source-fetch-max")
    on_exit(fn -> File.rm_rf!(tmp) end)

    provider = manifest_provider!("deep_vellum_official_store")
    capped_provider = put_in(provider, ["max_bytes", "response"], 4)
    manifest = manifest_with_provider(capped_provider)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, "12345")
    end

    assert_raise SourceError, ~r/exceeds max_bytes 4/, fn ->
      SourceFetcher.fetch!(
        "deep_vellum_official_store",
        "https://store.deepvellum.org/products.json?limit=250",
        tmp,
        dataset_dir: @dataset_dir,
        manifest: manifest,
        req_options: [plug: plug]
      )
    end

    assert File.ls!(tmp) == []

    missing_cap_provider = put_in(provider, ["max_bytes", "response"], 0)

    assert_raise SourceError, ~r/max_bytes must be a positive integer/, fn ->
      SourceFetcher.fetch!(
        "deep_vellum_official_store",
        "https://store.deepvellum.org/products.json?limit=250",
        tmp,
        dataset_dir: @dataset_dir,
        manifest: manifest_with_provider(missing_cap_provider),
        req_options: [plug: plug]
      )
    end

    no_max_bytes_provider = Map.delete(provider, "max_bytes")

    assert_raise SourceError, ~r/max_bytes must be a positive integer/, fn ->
      SourceFetcher.fetch!(
        "deep_vellum_official_store",
        "https://store.deepvellum.org/products.json?limit=250",
        tmp,
        dataset_dir: @dataset_dir,
        manifest: manifest_with_provider(no_max_bytes_provider),
        req_options: [plug: plug]
      )
    end

    no_response_cap_provider = put_in(provider, ["max_bytes"], %{})

    assert_raise SourceError, ~r/max_bytes must be a positive integer/, fn ->
      SourceFetcher.fetch!(
        "deep_vellum_official_store",
        "https://store.deepvellum.org/products.json?limit=250",
        tmp,
        dataset_dir: @dataset_dir,
        manifest: manifest_with_provider(no_response_cap_provider),
        req_options: [plug: plug]
      )
    end
  end

  defp unique_tmp_dir(label) do
    Path.join(System.tmp_dir!(), "hiraeth-#{label}-#{System.unique_integer([:positive])}")
  end

  defp manifest_provider!(provider) do
    @dataset_dir
    |> Hiraeth.RealCatalog.Dataset.load_source_authority_manifest()
    |> elem(1)
    |> Map.fetch!("providers")
    |> Enum.find(&(&1["provider"] == provider)) ||
      flunk("missing provider #{provider}")
  end

  defp manifest_with_provider(provider) do
    {:ok, manifest} = Hiraeth.RealCatalog.Dataset.load_source_authority_manifest(@dataset_dir)

    providers =
      Enum.map(manifest["providers"], fn current ->
        if current["provider"] == provider["provider"], do: provider, else: current
      end)

    Map.put(manifest, "providers", providers)
  end
end
