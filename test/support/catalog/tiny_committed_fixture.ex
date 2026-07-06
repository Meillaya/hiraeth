defmodule Hiraeth.Catalog.TinyCommittedFixture do
  @moduledoc false

  alias Hiraeth.RealCatalog.Dataset

  def create! do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-tiny-committed-catalog-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    write_catalog_fixture!(tmp)
    tmp
  end

  defp write_catalog_fixture!(tmp) do
    provider = "archipelago_books_official_store"
    source_uri = "https://archipelagobooks.org/book/tiny-committed-catalog/"
    field_source = field_source(provider, source_uri)

    File.write!(
      Path.join(tmp, "tiny_committed_catalog.json"),
      Jason.encode!(payload(provider, source_uri, field_source), pretty: true)
    )

    File.write!(
      Path.join(tmp, Dataset.source_authority_manifest_file()),
      Jason.encode!(authority_manifest(provider, source_uri), pretty: true)
    )
  end

  defp field_source(provider, source_uri) do
    %{
      provider: provider,
      source_uri: source_uri,
      source_type: "publisher_dataset",
      rights_basis: "Deterministic committed catalog fixture equivalent for test-only metadata."
    }
  end

  defp payload(provider, source_uri, field_source) do
    %{
      provider: provider,
      retrieved_at: "2026-07-02T00:00:00Z",
      license_note: "Deterministic committed catalog fixture equivalent for test-only metadata.",
      provider_permissions: provider_permissions(provider, source_uri),
      records: [record(source_uri, field_source)]
    }
  end

  defp provider_permissions(provider, source_uri) do
    %{
      provider: provider,
      source_urls: [source_uri],
      source_hosts: ["archipelagobooks.org"],
      cover_hosts: ["archipelagobooks.org", "covers.openlibrary.org"],
      permission_basis:
        "Deterministic committed catalog fixture equivalent for test-only metadata.",
      cover_cache_policy: "cache_allowed",
      excluded_content: ["cart_checkout_account", "inventory_state", "user_reviews"],
      takedown_contact: "https://archipelagobooks.org/contact/",
      not_legal_advice: "Test fixture metadata only; not legal advice."
    }
  end

  defp record(source_uri, field_source) do
    %{
      source_uri: source_uri,
      source_product_id: "tiny-committed-catalog-9781939810175",
      source_sku: "9781939810175",
      publisher: "Archipelago Books",
      imprint: nil,
      work: %{title: "Tiny Committed Catalog", subtitle: nil, publication_state: "published"},
      edition: edition(),
      contributors: [%{name: "Fixture Author", role: "author"}],
      displayed_fields: displayed_fields(),
      curation: %{
        status: "approved",
        notes: "Deterministic tiny committed catalog fixture equivalent."
      },
      no_cover_reason: "Tiny committed fixture intentionally omits covers.",
      field_sources: field_sources(field_source)
    }
  end

  defp edition do
    %{
      title: "Tiny Committed Catalog",
      subtitle: nil,
      format: "paperback",
      published_on: "2026-07-02",
      isbn_13: "9781939810175"
    }
  end

  defp displayed_fields do
    ["title", "contributors", "publisher", "format", "published_on", "isbn_13"]
  end

  defp field_sources(field_source) do
    Map.new(displayed_fields(), &{&1, field_source})
  end

  defp authority_manifest(provider, source_uri) do
    %{
      providers: [
        %{
          provider: provider,
          coverage: %{expected_record_count: 1},
          allowed_source_urls: [source_uri],
          allowed_source_types: ["publisher_dataset"],
          max_bytes: %{response: 100_000}
        }
      ],
      completeness_boundary: "deterministic test-only committed catalog equivalent"
    }
  end
end
