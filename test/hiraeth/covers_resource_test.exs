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

    assert {:error, thumbnail_error} =
             CoverAsset
             |> Ash.Changeset.for_create(:create, %{
               source_url: "https://covers.example.test/thumb-disallowed.jpg",
               provider: "fixture-covers",
               rights_basis: "provider_link_allowed",
               cache_policy: "link_only",
               thumbnail_file_path: "priv/static/covers/cache/thumb-disallowed.jpg"
             })
             |> Ash.create(actor: admin)

    assert Exception.message(thumbnail_error) =~ "cache"

    cached =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/cache-allowed.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: "priv/static/covers/cache/cache-allowed.jpg",
        thumbnail_file_path: "priv/static/covers/cache/cache-allowed-thumb.jpg"
      })

    assert cached.cached_file_path == "priv/static/covers/cache/cache-allowed.jpg"
    assert cached.thumbnail_file_path == "priv/static/covers/cache/cache-allowed-thumb.jpg"
  end

  test "public resolver prefers locally cached cover paths when cache rights permit", %{
    admin: admin,
    edition: edition
  } do
    cached_path = "priv/static/covers/cache/cache-preferred.jpg"
    thumbnail_path = "priv/static/covers/cache/cache-preferred-thumb.jpg"
    File.mkdir_p!(Path.dirname(cached_path))
    File.write!(cached_path, "cached cover bytes")
    File.write!(thumbnail_path, "cached thumbnail bytes")

    on_exit(fn ->
      File.rm(cached_path)
      File.rm(thumbnail_path)
    end)

    cached =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/cache-preferred.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: cached_path,
        thumbnail_file_path: thumbnail_path
      })

    assignment!(admin, edition, cached)

    assert Covers.public_cover_asset?(cached)

    assert %{
             source_url: "https://covers.example.test/cache-preferred.jpg",
             cached_file_path: "priv/static/covers/cache/cache-preferred.jpg",
             public_url: "/covers/cache/cache-preferred.jpg",
             thumbnail_file_path: "priv/static/covers/cache/cache-preferred-thumb.jpg",
             thumbnail_url: "/covers/cache/cache-preferred-thumb.jpg"
           } = Covers.public_cover_for_edition(edition.id)
  end

  test "purge cached cover removes original and thumbnail derivatives", %{admin: admin} do
    cached_path = "priv/static/covers/cache/purge-original.jpg"
    thumbnail_path = "priv/static/covers/cache/purge-thumb.jpg"
    File.mkdir_p!(Path.dirname(cached_path))
    File.write!(cached_path, "cached cover bytes")
    File.write!(thumbnail_path, "cached thumbnail bytes")

    on_exit(fn ->
      File.rm(cached_path)
      File.rm(thumbnail_path)
    end)

    cached =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/purge-cover.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: cached_path,
        thumbnail_file_path: thumbnail_path
      })

    purged = Covers.purge_cached_cover!(cached)

    refute File.exists?(cached_path)
    refute File.exists?(thumbnail_path)
    assert purged.cached_file_path == nil
    assert purged.thumbnail_file_path == nil
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

  test "public resolver records cacheable provenance but hides remote cover before local cache warmup",
       %{
         admin: admin,
         edition: edition
       } do
    cacheable =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/cacheable-before-warmup.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: nil
      })

    assignment!(admin, edition, cacheable)

    assert Covers.public_cover_provenance_valid?(cacheable)
    refute Covers.public_cover_asset?(cacheable)

    assert Covers.public_cover_for_edition(edition.id) == Covers.fallback_cover()
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

  test "cover cache task helper writes deterministic local files and exposes public URL", %{
    admin: admin,
    edition: edition
  } do
    cache_root =
      Path.join(
        "priv/static/covers/cache",
        "test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(cache_root) end)

    cacheable =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/cache-task.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: nil
      })

    assignment!(admin, edition, cacheable)

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://covers.example.test/cache-task.jpg"],
        fetch: fn "https://covers.example.test/cache-task.jpg" -> "fake image bytes" end,
        thumbnailer: fn _cache_path, thumbnail_path ->
          File.write!(thumbnail_path, "fake thumbnail bytes")
          {:ok, thumbnail_path}
        end
      )

    assert %{cached: 1, skipped: 0, assets: [cached_asset]} = summary
    assert File.read!(cached_asset.cached_file_path) == "fake image bytes"
    assert String.starts_with?(cached_asset.cached_file_path, cache_root)

    assert %{
             cached_file_path: cached_path,
             public_url: public_url
           } = Covers.public_cover_for_edition(edition.id)

    assert cached_path == cached_asset.cached_file_path
    assert public_url =~ "/covers/cache/test-"

    skipped =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://covers.example.test/cache-task.jpg"],
        fetch: fn _url -> raise "already cached covers should be skipped" end
      )

    assert %{cached: 0, skipped: 1} = skipped

    forced =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://covers.example.test/cache-task.jpg"],
        force?: true,
        fetch: fn "https://covers.example.test/cache-task.jpg" -> "new fake image bytes" end
      )

    assert %{cached: 1, skipped: 0, assets: [forced_asset]} = forced
    assert File.read!(forced_asset.cached_file_path) == "new fake image bytes"
  end

  test "cover cache task backfills missing thumbnails from already cached originals", %{
    admin: admin,
    edition: edition
  } do
    cache_root =
      Path.join(
        "priv/static/covers/cache",
        "backfill-thumb-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(cache_root) end)

    cached_path = Path.join(cache_root, "already-cached.jpg")
    File.mkdir_p!(cache_root)
    File.write!(cached_path, "cached original bytes")

    cacheable =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/backfill-thumbnail.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: cached_path,
        thumbnail_file_path: nil
      })

    assignment!(admin, edition, cacheable)

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://covers.example.test/backfill-thumbnail.jpg"],
        fetch: fn _url -> raise "cached original should not be fetched" end,
        thumbnailer: fn ^cached_path, thumbnail_path ->
          File.write!(thumbnail_path, "thumbnail bytes")
          {:ok, thumbnail_path}
        end
      )

    assert %{cached: 1, skipped: 0, assets: [updated]} = summary
    assert File.read!(updated.cached_file_path) == "cached original bytes"
    assert File.read!(updated.thumbnail_file_path) == "thumbnail bytes"
    assert Covers.public_cover_asset?(updated)
  end

  test "cover cache task bounds hung thumbnail generation", %{admin: admin, edition: edition} do
    cache_root =
      Path.join(
        "priv/static/covers/cache",
        "hung-thumb-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(cache_root) end)

    cacheable =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/hung-thumbnail.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: nil
      })

    assignment!(admin, edition, cacheable)

    {elapsed_microseconds, summary} =
      :timer.tc(fn ->
        Covers.cache_public_covers!(
          cache_root: cache_root,
          source_urls: ["https://covers.example.test/hung-thumbnail.jpg"],
          fetch: fn "https://covers.example.test/hung-thumbnail.jpg" -> "fake image bytes" end,
          thumbnail_timeout: 25,
          thumbnailer: fn _source_path, _thumbnail_path ->
            receive do
              :release_thumbnail -> :unexpected
            end
          end
        )
      end)

    assert elapsed_microseconds < 750_000
    assert %{cached: 1, skipped: 0, assets: [cached_asset]} = summary
    assert File.read!(cached_asset.cached_file_path) == "fake image bytes"
    assert cached_asset.thumbnail_file_path == nil
  end

  test "public cache policy rejects missing cached files and cache task refreshes them", %{
    admin: admin,
    edition: edition
  } do
    cache_root =
      Path.join(
        "priv/static/covers/cache",
        "missing-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(cache_root) end)

    stale_path = Path.join(cache_root, "stale.jpg")

    stale =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/stale-cache.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: stale_path
      })

    assignment!(admin, edition, stale)

    refute Covers.public_cover_asset?(stale)
    assert Covers.public_cover_for_edition(edition.id) == Covers.fallback_cover()

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://covers.example.test/stale-cache.jpg"],
        fetch: fn "https://covers.example.test/stale-cache.jpg" -> "restored bytes" end
      )

    assert %{cached: 1, skipped: 0, assets: [refreshed]} = summary
    assert File.read!(refreshed.cached_file_path) == "restored bytes"
    assert Covers.public_cover_asset?(refreshed)
  end

  test "cache task skips unsafe source URLs before fetching", %{admin: admin} do
    _unsafe =
      cover_asset!(admin, %{
        source_url: "https://evil.example.test/unsafe.jpg",
        provider: "fixture-covers",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed"
      })

    summary =
      Covers.cache_public_covers!(
        source_urls: ["https://evil.example.test/unsafe.jpg"],
        fetch: fn _url -> raise "unsafe source URL should not be fetched" end
      )

    assert %{cached: 0, skipped: 0, assets: []} = summary
  end

  test "cache task does not follow redirects from allowlisted cover hosts", %{admin: admin} do
    parent = self()

    _redirecting =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/redirect.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed"
      })

    plug = fn conn ->
      send(parent, {:cover_request, conn.scheme, conn.host, conn.request_path})
      Req.Test.redirect(conn, external: "http://169.254.169.254/latest/meta-data")
    end

    summary =
      Covers.cache_public_covers!(
        source_urls: ["https://covers.example.test/redirect.jpg"],
        req_options: [plug: plug]
      )

    assert %{cached: 0, skipped: 0, failed: 1, failures: [%{reason: reason}]} = summary
    assert reason =~ "status 302"
    assert_received {:cover_request, :https, "covers.example.test", "/redirect.jpg"}
    refute_receive {:cover_request, _scheme, "169.254.169.254", _path}
  end

  test "cache task rejects cache roots outside the public cover cache directory" do
    assert_raise ArgumentError, ~r|cache_root must stay under priv/static/covers/cache|, fn ->
      Covers.cache_public_covers!(cache_root: "tmp/hiraeth-cover-cache")
    end
  end

  test "cache task skips fetch failures unless strict mode is requested", %{
    admin: admin,
    edition: edition
  } do
    failing =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/fetch-failure.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed"
      })

    assignment!(admin, edition, failing)

    summary =
      Covers.cache_public_covers!(
        source_urls: ["https://covers.example.test/fetch-failure.jpg"],
        fetch: fn "https://covers.example.test/fetch-failure.jpg" -> raise "network down" end
      )

    assert %{cached: 0, skipped: 0, failed: 1, failures: [%{reason: "network down"}]} = summary

    assert_raise RuntimeError, ~r/cover cache failed.*network down/, fn ->
      Covers.cache_public_covers!(
        strict?: true,
        source_urls: ["https://covers.example.test/fetch-failure.jpg"],
        fetch: fn "https://covers.example.test/fetch-failure.jpg" -> raise "network down" end
      )
    end
  end

  test "cache task bounds hung fetches with a timeout", %{admin: admin, edition: edition} do
    hanging =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/timeout.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed"
      })

    assignment!(admin, edition, hanging)

    summary =
      Covers.cache_public_covers!(
        timeout: 10,
        max_concurrency: 1,
        source_urls: ["https://covers.example.test/timeout.jpg"],
        fetch: fn "https://covers.example.test/timeout.jpg" -> Process.sleep(:infinity) end
      )

    assert %{cached: 0, skipped: 0, failed: 1, failures: [%{source_url: nil}]} = summary
  end

  test "public cache policy rejects cached paths outside static cache root", %{admin: admin} do
    unsafe =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/unsafe-cache-root.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: "tmp/unsafe-cache-root.jpg"
      })

    refute Covers.public_cover_asset?(unsafe)

    assert Covers.public_cover_rejection_reason(unsafe) ==
             "cached cover file path must be under priv/static/covers/cache"
  end

  test "public cache policy rejects symlinked cached paths inside static cache root", %{
    admin: admin
  } do
    cache_root =
      Path.join(
        "priv/static/covers/cache",
        "symlink-#{System.unique_integer([:positive])}"
      )

    outside_dir =
      Path.join(System.tmp_dir!(), "hiraeth-cover-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(cache_root)
    File.mkdir_p!(outside_dir)

    outside_path = Path.join(outside_dir, "outside.jpg")
    symlink_path = Path.join(cache_root, "linked.jpg")
    File.write!(outside_path, "outside bytes")

    case File.ln_s(outside_path, symlink_path) do
      :ok ->
        on_exit(fn ->
          File.rm_rf!(cache_root)
          File.rm_rf!(outside_dir)
        end)

        symlinked =
          cover_asset!(admin, %{
            source_url: "https://covers.example.test/symlink-cache.jpg",
            rights_basis: "local_cache_permitted",
            cache_policy: "cache_allowed",
            cached_file_path: symlink_path
          })

        refute Covers.public_cover_asset?(symlinked)

        assert Covers.public_cover_rejection_reason(symlinked) ==
                 "cached cover file path must be under priv/static/covers/cache"

      {:error, _reason} ->
        File.rm_rf!(cache_root)
        File.rm_rf!(outside_dir)
        :ok
    end
  end

  test "provenance audit writes zero invalid public covers", %{admin: admin, edition: edition} do
    cover =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/visible.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed"
      })

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
