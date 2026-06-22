defmodule Hiraeth.Support.DeepVellumStealthyFixture do
  @moduledoc false

  @provider "deep_vellum_official_store"
  @permission_basis "Deterministic test fixture derived from the official Deep Vellum public catalog shape with provenance preserved."

  def provider, do: @provider

  def records do
    [
      record(%{
        source_product_id: "rilke-shake-paperback",
        source_uri: "https://store.deepvellum.org/products/rilke-shake",
        title: "Rilke Shake",
        isbn_13: "9781941920756",
        published_on: "2015-03-24",
        contributors: [
          %{name: "Angélica Freitas", role: "author"},
          %{name: "Hilary Kaplan", role: "translator"}
        ],
        description:
          "A deterministic Deep Vellum detail fixture with script-like text treated as inert metadata.",
        cover_url: "https://cdn.shopify.com/deep-vellum/rilke-shake.jpg"
      }),
      record(%{
        source_product_id: "texas-the-great-theft-paperback",
        source_uri: "https://store.deepvellum.org/products/texas-the-great-theft",
        title: "Texas: The Great Theft",
        isbn_13: "9781941920763",
        published_on: "2015-04-14",
        contributors: [%{name: "Carmen Boullosa", role: "author"}],
        description:
          "A second enriched stealthy record from the deterministic Deep Vellum shape.",
        cover_url: "https://cdn.shopify.com/deep-vellum/texas-the-great-theft.jpg"
      })
    ]
  end

  def missing_contributors_record(record) do
    record
    |> put_in([:contributors], [])
    |> Map.put(:displayed_fields, [
      "title",
      "publisher",
      "format",
      "published_on",
      "isbn_13",
      "cover"
    ])
    |> Map.update!(:field_sources, &Map.drop(&1, ["contributors"]))
  end

  def write_dataset!(path, records) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(dataset(records), pretty: true))
  end

  def dataset(records) do
    %{
      provider: @provider,
      retrieved_at: "2026-06-22T00:00:00Z",
      license_note: @permission_basis,
      provider_permissions: %{
        provider: @provider,
        permission_basis: @permission_basis,
        cover_cache_policy: "cache_allowed",
        takedown_contact: "https://store.deepvellum.org/pages/contact-us",
        not_legal_advice: "Engineering provenance fixture; not legal advice.",
        source_urls: ["https://store.deepvellum.org/collections/all"],
        source_hosts: ["store.deepvellum.org"],
        cover_hosts: ["cdn.shopify.com", "covers.openlibrary.org"],
        excluded_content: [
          "cart_checkout_account",
          "inventory_state",
          "user_reviews",
          "raw_html_without_sanitization"
        ]
      },
      records: records
    }
  end

  defp record(attrs) do
    source_uri = Map.fetch!(attrs, :source_uri)
    title = Map.fetch!(attrs, :title)
    displayed_fields = displayed_fields()

    %{
      source_uri: source_uri,
      source_product_id: Map.fetch!(attrs, :source_product_id),
      source_sku: Map.fetch!(attrs, :isbn_13),
      publisher: "Deep Vellum",
      imprint: nil,
      work: %{
        title: title,
        subtitle: nil,
        original_title: nil,
        publication_state: "published",
        subjects: ["Deep Vellum", "Fiction"]
      },
      edition: %{
        title: title,
        subtitle: nil,
        format: "paperback",
        published_on: Map.fetch!(attrs, :published_on),
        isbn_13: Map.fetch!(attrs, :isbn_13)
      },
      contributors: Map.fetch!(attrs, :contributors),
      displayed_fields: displayed_fields,
      curation: %{
        status: "approved",
        notes: "Deterministic stealthy scrape fixture for end-to-end pipeline coverage."
      },
      storefront_url: source_uri,
      field_sources: field_sources(["subjects" | displayed_fields], source_uri),
      cover: %{
        source_url: Map.fetch!(attrs, :cover_url),
        provider: @provider,
        rights_basis: "local_cache_permitted",
        attribution_text: "Cover via Deep Vellum official store",
        attribution_url: source_uri,
        cache_policy: "cache_allowed"
      },
      description: Map.fetch!(attrs, :description),
      series: [],
      review_links: [],
      editorial_praise: []
    }
  end

  defp displayed_fields do
    [
      "title",
      "contributors",
      "publisher",
      "format",
      "published_on",
      "isbn_13",
      "cover",
      "description",
      "storefront_url"
    ]
  end

  defp field_sources(displayed_fields, source_uri) do
    Map.new(displayed_fields, fn field ->
      {field,
       %{
         provider: @provider,
         source_uri: source_uri,
         source_type: "publisher_dataset",
         rights_basis: @permission_basis
       }}
    end)
  end
end
