defmodule Hiraeth.TestSupport.ProviderIngestionWorkerEnrichmentRecords do
  @moduledoc false

  @provider "test_scrape_with_fallback"

  def incomplete_api_record do
    base_record("test-book", "Fallback API Book")
    |> Map.put(:contributors, [])
    |> put_in([:cover, :source_url], nil)
    |> put_in([:edition, :isbn_13], "9781939419545")
    |> put_in([:edition, :published_on], "2024-01-01")
    |> Map.put(:description, "original API description")
  end

  def complete_api_record do
    "complete-book"
    |> base_record("Complete API Book")
    |> put_in([:edition, :isbn_13], "9781939419545")
    |> put_in([:edition, :published_on], "2024-02-01")
    |> Map.put(:source_product_id, "fallback-api-complete-001")
    |> Map.put(:contributors, [%{name: "Complete Author", role: "author"}])
    |> Map.put(:description, "complete API description")
    |> put_in([:cover, :source_url], "https://images.testscraper.com/covers/complete-book.jpg")
  end

  def record_missing_contributors do
    "timeout-book"
    |> base_record("Timeout API Book")
    |> Map.put(:source_product_id, "fallback-api-timeout-001")
    |> Map.put(:contributors, [])
    |> Map.put(:description, nil)
    |> Map.put(:missing_fields, %{isbn_13: "not available from source"})
  end

  def record_with_non_binary_source_uri do
    123
    |> base_record("Malformed Source URI Book")
    |> Map.put(:source_product_id, "fallback-api-malformed-001")
    |> Map.put(:contributors, [])
    |> Map.put(:description, nil)
    |> Map.put(:missing_fields, %{isbn_13: "not available from source"})
    |> put_in([:cover, :source_url], nil)
  end

  defp base_record(handle_or_uri, title) do
    source_uri = source_uri(handle_or_uri)

    %{
      source_uri: source_uri,
      publisher: @provider,
      imprint: nil,
      source_product_id: "fallback-api-001",
      work: %{
        title: title,
        subtitle: nil,
        original_title: nil,
        original_language_code: nil,
        subjects: nil,
        publication_state: "published"
      },
      edition: %{
        title: title,
        subtitle: nil,
        format: "paperback",
        language_code: nil,
        page_count: nil,
        dimensions: nil,
        published_on: nil,
        isbn_13: nil
      },
      contributors: [%{name: "Fallback Author", role: "author"}],
      curation: %{status: "approved"},
      displayed_fields: ["title", "contributors", "publisher"],
      field_sources: %{
        "title" => field_source(source_uri),
        "contributors" => field_source(source_uri),
        "publisher" => field_source(source_uri)
      },
      cover: %{
        source_url: "https://images.testscraper.com/covers/test-book.jpg",
        provider: @provider,
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        attribution_text: nil,
        attribution_url: nil
      },
      missing_fields: %{},
      series: [],
      review_links: [],
      editorial_praise: [],
      description: "original API description",
      synopsis: nil,
      storefront_url: nil,
      source_sku: nil
    }
  end

  defp source_uri(value) when is_binary(value), do: "https://www.testscraper.com/catalog/#{value}"
  defp source_uri(value), do: value

  defp field_source(source_uri) do
    %{
      "provider" => @provider,
      "source_uri" => source_uri,
      "source_type" => "publisher_dataset",
      "rights_basis" => "public_domain"
    }
  end
end
