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
      assert gate.cover_hosts == MapSet.new(["cdn.sanity.io"])
      assert gate.cover_cache_policy == "link_only_until_explicit_cache_permission"
      assert gate.not_legal_advice?
      assert gate.permission_basis =~ "protected under copyright law"
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

    test "exports exactly one expansion provider policy for deterministic fixtures" do
      assert SourcePolicy.expansion_provider_slugs() == ["new_directions_official_site"]
      assert SourcePolicy.provider_policy_ready?("new_directions_official_site")
      refute SourcePolicy.provider_policy_ready?("deep_vellum_official_store")
      refute SourcePolicy.provider_policy_ready?("unknown_provider")
    end

    test "projects gate metadata into dataset provider_permissions shape" do
      metadata = SourcePolicy.provider_permission_metadata!("new_directions_official_site")

      assert metadata.provider == "new_directions_official_site"
      assert metadata.source_urls == ["https://www.ndbooks.com/books/"]
      assert metadata.source_hosts == ["www.ndbooks.com"]
      assert metadata.cover_hosts == ["cdn.sanity.io"]
      assert metadata.cover_cache_policy == "link_only_until_explicit_cache_permission"
      assert metadata.permission_basis =~ "Official New Directions pages"
      assert metadata.takedown_contact =~ "permissions [at] ndbooks.com"
      assert metadata.not_legal_advice =~ "not legal advice"
      assert "reviews" in metadata.excluded_content
    end

    test "validates source and cover URLs without broad off-host access" do
      provider = "new_directions_official_site"

      assert SourcePolicy.source_uri_allowed?(provider, "https://www.ndbooks.com/books/a-book/")
      assert SourcePolicy.cover_uri_allowed?(provider, "https://cdn.sanity.io/images/example.jpg")
      refute SourcePolicy.cover_cache_allowed?(provider)

      refute SourcePolicy.source_uri_allowed?(provider, "http://www.ndbooks.com/books/a-book/")

      refute SourcePolicy.source_uri_allowed?(
               provider,
               "https://ndpublishing.myshopify.com/products/a-book"
             )

      refute SourcePolicy.cover_uri_allowed?(provider, "https://cdn.shopify.com/s/files/book.jpg")
      refute SourcePolicy.cover_uri_allowed?(provider, "https://www.ndbooks.com/images/book.jpg")
    end
  end
end
