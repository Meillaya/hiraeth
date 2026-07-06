defmodule Hiraeth.TestSupport.MixTaskMocks.MockSidecarClient do
  def health(_opts \\ []) do
    {:ok, %{status: "ok", scrapling: true}}
  end

  def fetch(_provider_config, _opts \\ []) do
    {:ok, %{records: [api_record()]}}
  end

  def scrape(_provider_config, _opts \\ []) do
    {:ok, %{records: [scrape_record()]}}
  end

  def detail(_source_uri, _provider, _opts) do
    {:ok, %{}}
  end

  defp api_record do
    %{
      source_uri: "https://www.testpublisher.com/books/test-book",
      publisher: "Test Publisher",
      imprint: nil,
      source_product_id: "test-book-001",
      work: %{
        title: "Test Book Title",
        subtitle: nil,
        original_title: nil,
        original_language_code: nil,
        subjects: nil,
        publication_state: "published"
      },
      edition: %{
        title: "Test Book Title",
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
        "title" => %{
          "provider" => "test_publisher_api",
          "source_uri" => "https://www.testpublisher.com/books/test-book",
          "source_type" => "publisher_dataset",
          "rights_basis" => "public_domain"
        },
        "contributors" => %{
          "provider" => "test_publisher_api",
          "source_uri" => "https://www.testpublisher.com/books/test-book",
          "source_type" => "publisher_dataset",
          "rights_basis" => "public_domain"
        },
        "publisher" => %{
          "provider" => "test_publisher_api",
          "source_uri" => "https://www.testpublisher.com/books/test-book",
          "source_type" => "publisher_dataset",
          "rights_basis" => "public_domain"
        }
      },
      cover: %{
        source_url: "https://cdn.testpublisher.com/covers/test-book.jpg",
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

  defp scrape_record do
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
