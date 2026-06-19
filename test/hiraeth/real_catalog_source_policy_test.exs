defmodule Hiraeth.RealCatalogSourcePolicyTest do
  use ExUnit.Case, async: true

  alias Hiraeth.RealCatalog.SourcePolicy

  describe "New Directions provider gate" do
    test "records source, permission, cover, takedown, exclusion, and legal-review notes" do
      gate = SourcePolicy.provider_gate!("new_directions_official_site")

      assert gate.provider == "new_directions_official_site"
      assert gate.name == "New Directions"
      assert "https://www.ndbooks.com/books/" in gate.source_urls
      assert "https://www.ndbooks.com/permissions/" in gate.permission_urls
      assert "https://www.ndbooks.com/about/contact/" in gate.contact_urls
      assert gate.source_hosts == MapSet.new(["www.ndbooks.com"])
      assert gate.cover_hosts == MapSet.new(["cdn.sanity.io", "covers.openlibrary.org"])
      assert gate.cover_cache_policy == "cache_allowed"
      assert gate.not_legal_advice?
      assert gate.permission_basis =~ "public display depends on provenance"
      assert gate.takedown_contact =~ "permissions [at] ndbooks.com"
      assert "raw_html" in gate.excluded_content
      assert "prices" in gate.excluded_content
      assert "reviews" in gate.excluded_content

      assert SourcePolicy.source_host_allowed?(gate.provider, "www.ndbooks.com")
      assert SourcePolicy.cover_host_allowed?(gate.provider, "cdn.sanity.io")
      refute SourcePolicy.source_host_allowed?(gate.provider, "ndpublishing.myshopify.com")
      refute SourcePolicy.cover_host_allowed?(gate.provider, "cdn.shopify.com")
    end

    test "readiness is false unless every required gate field is present" do
      assert SourcePolicy.provider_gate_ready?("new_directions_official_site")
      refute SourcePolicy.provider_gate_ready?("unknown_provider")
    end

    test "exports approved expansion provider policies for deterministic fixtures" do
      assert SourcePolicy.expansion_provider_slugs() == [
               "new_directions_official_site",
               "transit_books_official_site"
             ]

      assert SourcePolicy.provider_policy_ready?("new_directions_official_site")
      assert SourcePolicy.provider_policy_ready?("transit_books_official_site")
      refute SourcePolicy.provider_policy_ready?("deep_vellum_official_store")
      refute SourcePolicy.provider_policy_ready?("unknown_provider")
    end

    test "projects gate metadata into dataset provider_permissions shape" do
      metadata = SourcePolicy.provider_permission_metadata!("new_directions_official_site")

      assert metadata.provider == "new_directions_official_site"
      assert "https://www.ndbooks.com/books/" in metadata.source_urls
      assert metadata.source_hosts == ["www.ndbooks.com"]
      assert metadata.cover_hosts == ["cdn.sanity.io", "covers.openlibrary.org"]
      assert metadata.cover_cache_policy == "cache_allowed"
      assert metadata.permission_basis =~ "Official New Directions pages"
      assert metadata.takedown_contact =~ "permissions [at] ndbooks.com"
      assert metadata.not_legal_advice =~ "not legal advice"
      assert "reviews" in metadata.excluded_content
    end

    test "validates source and cover URLs without broad off-host access" do
      provider = "new_directions_official_site"

      assert SourcePolicy.source_uri_allowed?(provider, "https://www.ndbooks.com/books/a-book/")
      assert SourcePolicy.source_uri_allowed?(provider, "https://www.ndbooks.com/book/a-book/")
      assert SourcePolicy.purchase_uri_allowed?(provider, "https://www.ndbooks.com/book/a-book/")
      assert SourcePolicy.cover_uri_allowed?(provider, "https://cdn.sanity.io/images/example.jpg")
      assert SourcePolicy.cover_cache_allowed?(provider)

      refute SourcePolicy.source_uri_allowed?(provider, "http://www.ndbooks.com/books/a-book/")

      refute SourcePolicy.source_uri_allowed?(
               provider,
               "https://ndpublishing.myshopify.com/products/a-book"
             )

      refute SourcePolicy.cover_uri_allowed?(provider, "https://cdn.shopify.com/s/files/book.jpg")
      refute SourcePolicy.cover_uri_allowed?(provider, "https://www.ndbooks.com/images/book.jpg")
    end

    test "allows only link-first or authorized publisher review excerpts" do
      provider = "new_directions_official_site"

      assert SourcePolicy.review_link_allowed?(provider, %{
               source: "Publisher review page",
               source_uri: "https://www.ndbooks.com/book/a-book/",
               rights_basis: "link_only"
             })

      refute SourcePolicy.review_link_allowed?(provider, %{
               source: "Publisher review page",
               source_uri: "https://www.ndbooks.com/book/a-book/"
             })

      assert SourcePolicy.review_link_allowed?(provider, %{
               source: "Publisher review page",
               source_uri: "https://www.ndbooks.com/book/a-book/",
               rights_basis: "publisher_supplied",
               excerpt: "A short publisher-supplied editorial excerpt."
             })

      refute SourcePolicy.review_link_allowed?(provider, %{
               source: "Reader",
               source_uri: "https://www.ndbooks.com/book/a-book/",
               rights_basis: "user_review",
               excerpt: "A user review must not be displayed."
             })

      refute SourcePolicy.review_link_allowed?(provider, %{
               source: "Off-host review",
               source_uri: "https://reviews.example.test/a-book",
               rights_basis: "publisher_supplied",
               excerpt: "Off-host excerpts are not provider-authorized source links."
             })
    end
  end

  describe "Transit Books provider gate" do
    test "records source, permission, cover, takedown, exclusion, and legal-review notes" do
      gate = SourcePolicy.provider_gate!("transit_books_official_site")

      assert gate.provider == "transit_books_official_site"
      assert gate.name == "Transit Books"
      assert "https://www.transitbooks.org/books" in gate.source_urls
      assert "https://www.transitbooks.org/catalogs" in gate.source_urls
      assert "https://www.transitbooks.org/rights" in gate.permission_urls
      assert "https://www.transitbooks.org/about" in gate.contact_urls
      assert gate.source_hosts == MapSet.new(["www.transitbooks.org"])

      assert gate.cover_hosts ==
               MapSet.new([
                 "covers.openlibrary.org",
                 "images.squarespace-cdn.com",
                 "static1.squarespace.com"
               ])

      assert gate.cover_cache_policy == "cache_allowed"
      assert gate.not_legal_advice?
      assert gate.permission_basis =~ "Official Transit Books pages"
      assert gate.permission_basis =~ "allowlisted Squarespace image hosts"
      assert gate.takedown_contact =~ "https://www.transitbooks.org/rights"
      assert gate.takedown_contact =~ "https://www.transitbooks.org/about"
      assert "raw_html" in gate.excluded_content
      assert "jacket_copy_dumps" in gate.excluded_content
      assert "author_bios" in gate.excluded_content
      assert "reviews" in gate.excluded_content
      assert "prices" in gate.excluded_content
      assert "inventory" in gate.excluded_content
      assert "unattributed_cover_images" in gate.excluded_content

      assert SourcePolicy.source_host_allowed?(gate.provider, "www.transitbooks.org")
      refute SourcePolicy.source_host_allowed?(gate.provider, "transitbooks.org")

      refute SourcePolicy.source_host_allowed?(
               gate.provider,
               "www.transitchildrenseditions.org"
             )

      refute SourcePolicy.cover_host_allowed?(gate.provider, "www.transitbooks.org")
      assert SourcePolicy.cover_host_allowed?(gate.provider, "images.squarespace-cdn.com")
    end

    test "readiness allows the Transit cover provider gate" do
      assert SourcePolicy.provider_gate_ready?("transit_books_official_site")
      assert SourcePolicy.provider_policy_ready?("transit_books_official_site")
      assert SourcePolicy.cover_cache_allowed?("transit_books_official_site")
    end

    test "projects Transit metadata into dataset provider_permissions shape" do
      metadata = SourcePolicy.provider_permission_metadata!("transit_books_official_site")

      assert metadata.provider == "transit_books_official_site"

      assert metadata.source_urls == [
               "https://www.transitbooks.org/books",
               "https://www.transitbooks.org/catalogs"
             ]

      assert metadata.source_hosts == ["www.transitbooks.org"]

      assert metadata.cover_hosts == [
               "covers.openlibrary.org",
               "images.squarespace-cdn.com",
               "static1.squarespace.com"
             ]

      assert metadata.cover_cache_policy == "cache_allowed"
      assert metadata.permission_basis =~ "Official Transit Books pages"
      assert metadata.takedown_contact =~ "https://www.transitbooks.org/rights"
      assert metadata.not_legal_advice =~ "not legal advice"
      assert "unattributed_cover_images" in metadata.excluded_content
    end

    test "validates Transit source and allowlisted cover URLs" do
      provider = "transit_books_official_site"

      assert SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/books")

      assert SourcePolicy.purchase_uri_allowed?(
               provider,
               "https://www.transitbooks.org/books/a-shining"
             )

      assert SourcePolicy.source_uri_allowed?(
               provider,
               "https://www.transitbooks.org/books/a-shining"
             )

      assert SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/catalogs")

      assert SourcePolicy.source_uri_allowed?(
               provider,
               "https://www.transitbooks.org/s/SS26_TransitCatalog_Adult.pdf"
             )

      assert SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/rights")
      assert SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/about")

      assert SourcePolicy.source_uri_allowed?(
               provider,
               "https://www.transitbooks.org/about/contact"
             )

      assert SourcePolicy.cover_cache_allowed?(provider)

      refute SourcePolicy.source_uri_allowed?(provider, "http://www.transitbooks.org/books")
      refute SourcePolicy.source_uri_allowed?(provider, "https://transitbooks.org/books")
      refute SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/")
      refute SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/shop")
      refute SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/account")

      refute SourcePolicy.source_uri_allowed?(
               provider,
               "https://www.transitbooks.org/s/not-a-pdf"
             )

      refute SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/cart")
      refute SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/checkout")
      refute SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/blog")
      refute SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/events")
      refute SourcePolicy.source_uri_allowed?(provider, "https://www.transitbooks.org/bookshelf")

      for traversal_uri <- [
            "https://www.transitbooks.org/books/../account",
            "https://www.transitbooks.org/books/%2e%2e%2faccount",
            "https://www.transitbooks.org/catalogs/%2e%2e/checkout",
            "https://www.transitbooks.org/catalogs/%2e%2e%2Fcheckout",
            "https://www.transitbooks.org/catalogs/%2E%2e/checkout",
            "https://www.transitbooks.org/s/../account.pdf",
            "https://www.transitbooks.org/s/%2e%2e%2faccount.pdf",
            "https://www.transitbooks.org/books/%2E%2E%5Caccount",
            "https://www.transitbooks.org/books/%252e%252e%252faccount",
            "https://www.transitbooks.org/books/%252E%252E%255Caccount",
            "https://www.transitbooks.org/s/%252e%252e%252f...pdf"
          ] do
        refute SourcePolicy.source_uri_allowed?(provider, traversal_uri)
      end

      refute SourcePolicy.source_uri_allowed?(
               provider,
               "https://www.transitchildrenseditions.org/books"
             )

      refute SourcePolicy.cover_uri_allowed?(
               provider,
               "https://www.transitbooks.org/book-cover.jpg"
             )

      assert SourcePolicy.cover_uri_allowed?(
               provider,
               "https://images.squarespace-cdn.com/book-cover.jpg"
             )
    end
  end
end
