defmodule Hiraeth.Ingestion.ProviderBackfillTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Ingestion.{ProviderBackfill, ProviderSource}

  @catalog_writer %{id: "provider-backfill-test", catalog_write?: true}

  setup do
    Repo.delete_all("provider_sources")
    :ok
  end

  test "build_inventory derives one canonical row per real publisher and provider manifest" do
    assert {:ok, providers} = ProviderBackfill.build_inventory()

    keys = Enum.map(providers, & &1.stable_source_key)
    deep_vellum = Enum.find(providers, &(&1.stable_source_key == "deep_vellum_official_store"))

    fitzcarraldo =
      Enum.find(providers, &(&1.stable_source_key == "fitzcarraldo_editions_official_site"))

    astra_house = Enum.find(providers, &(&1.stable_source_key == "astra_house_official_store"))

    assert length(providers) == 28
    assert length(keys) == length(Enum.uniq(keys))
    assert deep_vellum.provider_name == "Deep Vellum"
    assert deep_vellum.ingestion_mode == "scrape"
    assert deep_vellum.enabled? == true

    assert deep_vellum.manifest_uri ==
             "priv/catalog_sources/provider_manifests/deep_vellum_official_store.json"

    refute String.starts_with?(deep_vellum.manifest_uri, "/")
    refute deep_vellum.manifest_uri =~ "_build"
    assert "store.deepvellum.org" in deep_vellum.allowed_hosts
    assert fitzcarraldo.ingestion_mode == "manual"
    assert fitzcarraldo.enabled? == false
    assert "fitzcarraldoeditions.com" in fitzcarraldo.allowed_hosts
    assert astra_house.ingestion_mode == "scrape"
    assert astra_house.enabled? == true
  end

  test "apply! creates and updates provider source rows without duplicate stable source keys" do
    existing =
      ProviderSource
      |> Ash.Changeset.for_create(:create, %{
        stable_source_key: "fitzcarraldo_editions_official_site",
        provider_name: "Stale Fitzcarraldo",
        source_kind: "manual",
        ingestion_mode: "api",
        enabled?: true,
        allowed_hosts: ["stale.example.test"]
      })
      |> Ash.create!(actor: @catalog_writer)

    assert existing.provider_name == "Stale Fitzcarraldo"

    assert %{created: created, updated: updated, total: 28, providers: providers} =
             ProviderBackfill.apply!()

    rows = Ash.read!(ProviderSource, authorize?: false)
    keys = Enum.map(rows, & &1.stable_source_key)

    fitzcarraldo =
      Enum.find(rows, &(&1.stable_source_key == "fitzcarraldo_editions_official_site"))

    assert created == 27
    assert updated == 1
    assert length(rows) == 28
    assert keys -- Enum.uniq(keys) == []
    assert length(providers) == 28
    assert fitzcarraldo.provider_name == "Fitzcarraldo Editions"
    assert fitzcarraldo.source_kind == "publisher"
    assert fitzcarraldo.ingestion_mode == "manual"
    assert fitzcarraldo.enabled? == false
  end

  test "apply! disables active provider source rows outside the canonical inventory" do
    ProviderSource
    |> Ash.Changeset.for_create(:create, %{
      stable_source_key: "publisher:deep-vellum:manual-3970:manifest",
      provider_name: "Stale Deep Vellum Manual Manifest",
      source_kind: "publisher",
      ingestion_mode: "manifest",
      enabled?: true,
      manifest_uri: "https://www.deepvellum.org/catalog-manual-3970.json",
      allowed_hosts: ["www.deepvellum.org"]
    })
    |> Ash.create!(actor: @catalog_writer)

    assert %{
             created: 28,
             updated: 0,
             stale_disabled: 1,
             stale_provider_keys: ["publisher:deep-vellum:manual-3970:manifest"]
           } = ProviderBackfill.apply!()

    rows = Ash.read!(ProviderSource, authorize?: false)

    stale =
      Enum.find(rows, &(&1.stable_source_key == "publisher:deep-vellum:manual-3970:manifest"))

    assert length(rows) == 29
    assert stale.source_kind == "manual"
    assert stale.ingestion_mode == "manual"
    assert stale.enabled? == false
  end

  test "dry_run returns parsed provider posture without writing rows" do
    assert %{dry_run: true, total: 28, providers: providers} = ProviderBackfill.dry_run()

    assert [] = Ash.read!(ProviderSource, authorize?: false)
    assert Enum.any?(providers, &(&1["stable_source_key"] == "deep_vellum_official_store"))
    assert Enum.any?(providers, &(&1["stable_source_key"] == "and_other_stories_official_store"))
    assert Enum.any?(providers, &(&1["enabled?"] == false and &1["ingestion_mode"] == "manual"))

    manifest_uris =
      providers
      |> Enum.map(& &1["manifest_uri"])
      |> Enum.reject(&is_nil/1)

    assert manifest_uris != []

    assert Enum.all?(
             manifest_uris,
             &String.starts_with?(&1, "priv/catalog_sources/provider_manifests/")
           )

    refute Enum.any?(manifest_uris, &String.starts_with?(&1, "/"))
    refute Enum.any?(manifest_uris, &(&1 =~ "_build"))
    refute Enum.any?(manifest_uris, &(&1 =~ File.cwd!()))
  end

  test "build_inventory rejects malformed provider manifests" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-provider-backfill-#{System.unique_integer([:positive])}"
      )

    real_dir = Path.join(tmp, "real_publishers")
    manifest_dir = Path.join(tmp, "provider_manifests")

    File.mkdir_p!(real_dir)
    File.mkdir_p!(manifest_dir)
    File.write!(Path.join(manifest_dir, "broken.json"), Jason.encode!(%{"provider" => "broken"}))

    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:error, message} =
             ProviderBackfill.build_inventory(
               real_publishers_dir: real_dir,
               provider_manifests_dir: manifest_dir
             )

    assert message =~ "manifest validation failed"
    assert message =~ "broken.json"
  end
end
