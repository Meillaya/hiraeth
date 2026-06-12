defmodule Hiraeth.CoversResourceTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Accounts.User
  alias Hiraeth.Catalog.{Edition, Publisher, Work}
  alias Hiraeth.Covers
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}

  setup do
    admin =
      User
      |> Ash.Changeset.for_create(:seed_admin, %{
        email: "covers-admin-#{System.unique_integer([:positive])}@example.test",
        password: "correct horse battery staple",
        display_name: "Covers Admin"
      })
      |> Ash.create!(authorize?: false)

    edition = edition!(admin)
    %{admin: admin, edition: edition}
  end

  test "cover assets require source URL, provider, and rights basis", %{admin: admin} do
    assert {:error, error} =
             CoverAsset
             |> Ash.Changeset.for_create(:create, %{
               source_url: "https://covers.example.test/missing-provider.jpg",
               rights_basis: "provider_link_allowed"
             })
             |> Ash.create(actor: admin)

    assert Exception.message(error) =~ "is required"
  end

  test "public resolver returns fallback for missing covers and omits takedown assets", %{
    admin: admin,
    edition: edition
  } do
    assert Covers.public_cover_for_edition(Ash.UUID.generate()) == Covers.fallback_cover()

    takedown =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/takedown.jpg",
        takedown_state: "hidden"
      })

    assignment!(admin, edition, takedown)

    assert Covers.public_cover_for_edition(edition.id) == Covers.fallback_cover()
  end

  test "cached cover fields require explicit cache rights", %{admin: admin} do
    assert {:error, error} =
             CoverAsset
             |> Ash.Changeset.for_create(:create, %{
               source_url: "https://covers.example.test/cache-disallowed.jpg",
               provider: "fixture-covers",
               rights_basis: "provider_link_allowed",
               cache_policy: "link_only",
               cached_file_path: "priv/static/covers/cache-disallowed.jpg"
             })
             |> Ash.create(actor: admin)

    assert Exception.message(error) =~ "cache"

    cached =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/cache-allowed.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: "priv/static/covers/cache-allowed.jpg"
      })

    assert cached.cached_file_path == "priv/static/covers/cache-allowed.jpg"
  end

  test "public resolver prefers locally cached cover paths when cache rights permit", %{
    admin: admin,
    edition: edition
  } do
    cached =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/cache-preferred.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: "priv/static/covers/cache/cache-preferred.jpg"
      })

    assignment!(admin, edition, cached)

    assert Covers.public_cover_asset?(cached)

    assert %{
             source_url: "https://covers.example.test/cache-preferred.jpg",
             cached_file_path: "priv/static/covers/cache/cache-preferred.jpg",
             public_url: "/covers/cache/cache-preferred.jpg"
           } = Covers.public_cover_for_edition(edition.id)
  end

  test "public resolver still allows link-only remote covers when no local cache exists", %{
    admin: admin,
    edition: edition
  } do
    remote =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/link-only-fallback.jpg",
        rights_basis: "provider_link_allowed",
        cache_policy: "link_only",
        cached_file_path: nil
      })

    assignment!(admin, edition, remote)

    assert Covers.public_cover_asset?(remote)

    assert %{
             source_url: "https://covers.example.test/link-only-fallback.jpg",
             cached_file_path: nil,
             public_url: "https://covers.example.test/link-only-fallback.jpg"
           } = Covers.public_cover_for_edition(edition.id)
  end

  test "takedown hides cached covers and does not expose stale local paths", %{
    admin: admin,
    edition: edition
  } do
    hidden_cached =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/hidden-cache.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: "priv/static/covers/cache/hidden-cache.jpg",
        takedown_state: "hidden"
      })

    assignment!(admin, edition, hidden_cached)

    refute Covers.public_cover_asset?(hidden_cached)
    assert Covers.public_cover_for_edition(edition.id) == Covers.fallback_cover()
  end

  test "provenance audit writes zero invalid public covers", %{admin: admin, edition: edition} do
    cover = cover_asset!(admin, %{source_url: "https://covers.example.test/visible.jpg"})
    assignment!(admin, edition, cover)

    audit = Covers.audit_public_cover_provenance!("artifacts/qa/covers/provenance-audit.json")

    assert audit.invalid_public_covers == []
    assert File.exists?("artifacts/qa/covers/provenance-audit.json")
  end

  defp edition!(admin) do
    publisher =
      Publisher
      |> Ash.Changeset.for_create(:create, %{
        name: "Cover Press #{System.unique_integer([:positive])}",
        slug: unique_slug("cover-press")
      })
      |> Ash.create!(actor: admin)

    work =
      Work
      |> Ash.Changeset.for_create(:create, %{
        title: "Cover Work",
        slug: unique_slug("cover-work")
      })
      |> Ash.create!(actor: admin)

    Edition
    |> Ash.Changeset.for_create(:create, %{
      title: "Cover Edition",
      slug: unique_slug("cover-edition"),
      work_id: work.id,
      publisher_id: publisher.id
    })
    |> Ash.create!(actor: admin)
  end

  defp cover_asset!(admin, attrs) do
    attrs =
      Map.merge(
        %{
          source_url: "https://covers.example.test/#{System.unique_integer([:positive])}.jpg",
          provider: "fixture-covers",
          rights_basis: "provider_link_allowed",
          cache_policy: "link_only",
          attribution_text: "Fixture cover provider",
          takedown_state: "visible"
        },
        attrs
      )

    CoverAsset
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: admin)
  end

  defp assignment!(admin, edition, cover_asset) do
    CoverAssignment
    |> Ash.Changeset.for_create(:create, %{
      edition_id: edition.id,
      cover_asset_id: cover_asset.id,
      position: 1,
      visible?: true
    })
    |> Ash.create!(actor: admin)
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
