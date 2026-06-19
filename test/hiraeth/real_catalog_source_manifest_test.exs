defmodule Hiraeth.RealCatalogSourceManifestTest do
  use ExUnit.Case, async: true

  alias Hiraeth.RealCatalog.SourcePolicy

  @manifest_path Path.expand(
                   "../../priv/catalog_sources/real_publishers/source_authority_manifest.json",
                   __DIR__
                 )

  @dataset_dir Path.expand("../../priv/catalog_sources/real_publishers", __DIR__)

  @expected_providers %{
    "deep_vellum_official_store" => "deep_vellum.json",
    "dalkey_archive_official_store" => "dalkey_archive.json",
    "archipelago_books_official_store" => "archipelago_books.json",
    "new_directions_official_site" => "new_directions.json",
    "transit_books_official_site" => "transit_books.json",
    "historical_materialism_official_site" => "historical_materialism.json",
    "semiotexte_official_site" => "semiotexte.json",
    "phoneme_media_official_store" => "phoneme_media.json",
    "a_strange_object_official_store" => "a_strange_object.json",
    "la_reunion_official_store" => "la_reunion.json",
    "fum_destampa_official_store" => "fum_destampa.json",
    "fitzcarraldo_editions_official_site" => "fitzcarraldo_editions.json",
    "nyrb_official_store" => "nyrb.json",
    "tilted_axis_press_official_site" => "tilted_axis_press.json",
    "mcnally_editions_official_site" => "mcnally_editions.json",
    "seven_stories_press_official_site" => "seven_stories_press.json",
    "unnamed_press_official_site" => "unnamed_press.json",
    "pushkin_press_official_site" => "pushkin_press.json"
  }

  describe "source authority manifest" do
    test "covers all current real publisher fixtures" do
      manifest = load_manifest!()

      providers = Map.new(manifest["providers"], &{&1["provider"], &1["dataset_file"]})

      assert providers == @expected_providers

      for {_provider, dataset_file} <- providers do
        assert File.exists?(Path.join(@dataset_dir, dataset_file))
      end
    end

    test "defines approved-source corpus boundaries instead of universal completeness" do
      manifest = load_manifest!()

      assert manifest["completeness_boundary"] == "approved_source_corpus"
      assert manifest["completeness_note"] =~ "not fabricated universal publisher history"

      for provider <- manifest["providers"] do
        assert provider["source_corpus_boundary"] =~ "official"
        assert "fabricated_metadata" in manifest["global_blocked_modes"]
      end
    end

    test "records authorized public extraction and requires deterministic bounded network evidence" do
      manifest = load_manifest!()

      refute "html_page_extraction" in manifest["global_blocked_modes"]
      assert manifest["network_policy"]["operator_authorized_public_html_extraction_allowed"]
      refute manifest["network_policy"]["normal_tests_live_network_allowed"]
      assert manifest["network_policy"]["requires_allowlist"]
      assert manifest["network_policy"]["requires_rate_limit"]
      assert manifest["network_policy"]["requires_max_bytes"]
      assert manifest["network_policy"]["requires_checksum"]

      for provider <- manifest["providers"] do
        refute "html_page_extraction" in provider["blocked_modes"]
        assert is_integer(provider["rate_limit"]["max_concurrency"])
        assert is_integer(provider["rate_limit"]["min_delay_ms"])
        assert is_integer(provider["max_bytes"]["response"])
        assert "checksum" in provider["required_evidence"]
        assert provider["coverage"]["count_source"] == "generated_public_source_corpus"
        assert is_integer(provider["coverage"]["expected_record_count"])
        assert provider["coverage"]["expected_record_count"] > 0
        assert provider["coverage"]["gap_policy"] == "import_with_gaps"
      end
    end

    test "keeps New Directions approved through operator-authorized official page extraction" do
      manifest = load_manifest!()
      new_directions = provider!(manifest, "new_directions_official_site")

      assert new_directions["status"] == "approved_official_html_source_available"
      assert is_nil(new_directions["expansion_state"])
      assert "https://www.ndbooks.com/sitemap-0.xml" in new_directions["allowed_source_urls"]
      assert "publisher_official_page" in new_directions["allowed_source_types"]
      refute "catalog_book_page_extraction" in new_directions["blocked_modes"]
    end

    test "keeps manifest host policy aligned with runtime source policy" do
      manifest = load_manifest!()

      for provider <- manifest["providers"] do
        provider_slug = provider["provider"]

        assert MapSet.new(provider["allowed_source_hosts"]) ==
                 SourcePolicy.source_hosts(provider_slug)

        assert MapSet.new(provider["allowed_cover_hosts"]) ==
                 SourcePolicy.cover_hosts(provider_slug)

        assert Map.get(provider, "allowed_source_path_prefixes", []) ==
                 SourcePolicy.source_path_prefixes(provider_slug)

        assert Map.get(provider, "allowed_pdf_path_prefixes", []) ==
                 SourcePolicy.source_pdf_path_prefixes(provider_slug)
      end
    end

    test "captures review and ISBN enrichment boundaries" do
      manifest = load_manifest!()

      assert manifest["review_policy"]["default"] == "link_only"

      assert "publisher_supplied_or_licensed_or_explicitly_authorized" in manifest[
               "review_policy"
             ]["displayable_excerpt_requires"]

      assert "user_reviews" in manifest["review_policy"]["blocked"]
      assert "scraped_review_text" in manifest["review_policy"]["blocked"]
      assert "unattributed_excerpts" in manifest["review_policy"]["blocked"]

      assert manifest["isbn_enrichment_policy"]["authoritative_source"] ==
               "publisher_or_authorized_source_artifact"

      assert manifest["isbn_enrichment_policy"]["open_library"] =~ "dumps_preferred_for_bulk"
    end
  end

  defp load_manifest! do
    @manifest_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp provider!(manifest, provider) do
    Enum.find(manifest["providers"], &(&1["provider"] == provider)) ||
      flunk("missing provider #{provider}")
  end
end
