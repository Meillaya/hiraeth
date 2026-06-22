defmodule Hiraeth.Ingestion.ReviewScrapeTaskTest do
  use Hiraeth.DataCase, async: false

  import ExUnit.CaptureIO

  @provider "review_scrape_test_provider"

  setup do
    staged_path = staged_path_for(@provider)
    current_path = current_path_for(@provider)

    File.rm(staged_path)
    File.rm(current_path)

    on_exit(fn ->
      File.rm(staged_path)
      File.rm(current_path)
    end)

    :ok
  end

  describe "diff report" do
    test "identical staged and current files print no differences" do
      record = sample_record()
      write_dataset(staged_path_for(@provider), @provider, [record])
      write_dataset(current_path_for(@provider), @provider, [record])

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Hiraeth.ReviewScrape.run(["--provider", @provider])
        end)

      assert output =~ "staged=1 current=1 new=0 missing=0 changed=0"
      assert output =~ "No differences found"
    end

    test "staged file with one new record prints +1 new" do
      current_record = sample_record(source_product_id: "existing-001", isbn_13: "9780000000001")

      new_record = sample_record(source_product_id: "new-002", isbn_13: "9780000000002")

      write_dataset(staged_path_for(@provider), @provider, [current_record, new_record])
      write_dataset(current_path_for(@provider), @provider, [current_record])

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Hiraeth.ReviewScrape.run(["--provider", @provider])
        end)

      assert output =~ "staged=2 current=1 new=1 missing=0 changed=0"
      assert output =~ "New records (+1)"
      assert output =~ "+ 9780000000002"
    end

    test "staged file with changed title for matched ISBN prints 1 changed" do
      current_record =
        sample_record(
          source_product_id: "existing-001",
          isbn_13: "9780000000001",
          title: "Old Title"
        )

      staged_record =
        sample_record(
          source_product_id: "existing-001",
          isbn_13: "9780000000001",
          title: "New Title"
        )

      write_dataset(staged_path_for(@provider), @provider, [staged_record])
      write_dataset(current_path_for(@provider), @provider, [current_record])

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Hiraeth.ReviewScrape.run(["--provider", @provider])
        end)

      assert output =~ "staged=1 current=1 new=0 missing=0 changed=1"
      assert output =~ "Changed records (~1)"
      assert output =~ "9780000000001"
      assert output =~ "work_title"
    end
  end

  describe "argument and file validation" do
    test "missing staged file exits 1" do
      File.rm(staged_path_for(@provider))

      output =
        capture_io(:stderr, fn ->
          assert catch_exit(Mix.Tasks.Hiraeth.ReviewScrape.run(["--provider", @provider])) ==
                   {:shutdown, 1}
        end)

      assert output =~ "staged dataset not found"
    end

    test "missing current file exits 1" do
      record = sample_record()
      write_dataset(staged_path_for(@provider), @provider, [record])
      File.rm(current_path_for(@provider))

      output =
        capture_io(:stderr, fn ->
          assert catch_exit(Mix.Tasks.Hiraeth.ReviewScrape.run(["--provider", @provider])) ==
                   {:shutdown, 1}
        end)

      assert output =~ "current dataset not found"
    end

    test "missing --provider exits 1" do
      output =
        capture_io(:stderr, fn ->
          assert catch_exit(Mix.Tasks.Hiraeth.ReviewScrape.run([])) == {:shutdown, 1}
        end)

      assert output =~ "Usage: mix hiraeth.review_scrape"
    end
  end

  defp staged_path_for(provider) do
    Application.app_dir(:hiraeth, "priv/catalog_sources/staged/#{provider}.json")
  end

  defp current_path_for(provider) do
    Application.app_dir(:hiraeth, "priv/catalog_sources/real_publishers/#{provider}.json")
  end

  defp write_dataset(path, provider, records) do
    File.mkdir_p!(Path.dirname(path))

    dataset = %{
      provider: provider,
      records: records,
      license_note: "test fixture",
      provider_permissions: %{}
    }

    File.write!(path, Jason.encode!(dataset, pretty: true))
  end

  defp sample_record(attrs \\ []) do
    title = Keyword.get(attrs, :title, "Sample Book")
    isbn_13 = Keyword.get(attrs, :isbn_13, "9780000000001")
    source_product_id = Keyword.get(attrs, :source_product_id, "sample-001")

    %{
      source_uri: "https://example.com/book/#{source_product_id}",
      source_product_id: source_product_id,
      publisher: "Test Publisher",
      imprint: nil,
      work: %{
        title: title,
        subtitle: nil,
        original_title: nil,
        publication_state: "published",
        subjects: []
      },
      edition: %{
        title: title,
        subtitle: nil,
        format: "paperback",
        published_on: "2024-01-01",
        isbn_13: isbn_13
      },
      contributors: [%{name: "Sample Author", role: "author"}],
      description: "A sample book description.",
      cover: %{
        source_url: "https://example.com/covers/#{source_product_id}.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed"
      },
      displayed_fields: [
        "title",
        "contributors",
        "publisher",
        "format",
        "published_on",
        "isbn_13",
        "cover",
        "description"
      ],
      curation: %{status: "approved"},
      storefront_url: "https://example.com/book/#{source_product_id}",
      source_sku: nil
    }
  end
end
