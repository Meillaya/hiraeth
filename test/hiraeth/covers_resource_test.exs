defmodule Hiraeth.CoversResourceTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Catalog.{Edition, Publisher, Work}
  alias Hiraeth.Covers
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}

  setup do
    admin = trusted_catalog_actor()
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

  test "public resolver hides link-only remote covers when no local cache exists", %{
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

    refute Covers.public_cover_asset?(remote)

    assert Covers.public_cover_rejection_reason(remote) ==
             "public cover display requires cache_allowed with a validated local cached file"

    assert Covers.public_cover_for_edition(edition.id) == Covers.fallback_cover()
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
        fetch: fn "https://covers.example.test/cache-task.jpg" -> jpeg_bytes() end,
        thumbnailer: fn _cache_path, thumbnail_path ->
          File.write!(thumbnail_path, "fake thumbnail bytes")
          {:ok, thumbnail_path}
        end
      )

    assert %{cached: 1, skipped: 0, assets: [cached_asset]} = summary
    assert File.read!(cached_asset.cached_file_path) == jpeg_bytes()
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
        fetch: fn "https://covers.example.test/cache-task.jpg" -> alternate_jpeg_bytes() end
      )

    assert %{cached: 1, skipped: 0, assets: [forced_asset]} = forced
    assert File.read!(forced_asset.cached_file_path) == alternate_jpeg_bytes()
  end

  test "cover cache task rejects oversized response bodies before writing cache files", %{
    admin: admin
  } do
    cache_root = unique_cache_root("oversized-body")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    oversized_body = png_bytes() <> String.duplicate("x", 64)

    oversized =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/oversized-body.png",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: nil
      })

    expected_cache_path = Covers.cache_path(oversized, cache_root)

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://covers.example.test/oversized-body.png"],
        max_body_size: byte_size(png_bytes()),
        fetch: fn "https://covers.example.test/oversized-body.png" -> oversized_body end,
        thumbnailer: fn _cache_path, _thumbnail_path -> nil end
      )

    assert %{cached: 0, skipped: 0, failed: 1, failures: [%{reason: reason}]} = summary
    assert reason =~ "body size"
    assert reason =~ "exceeds"
    refute File.exists?(expected_cache_path)
  end

  test "cover cache task restores the Bob and Hilbert cover even when it is larger than the old 10 MiB cap",
       %{
         admin: admin
       } do
    cache_root = unique_cache_root("archipelago-bob-hilbert-large-cover")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    cover =
      cover_asset!(admin, %{
        source_url:
          "https://archipelagobooks.org/wp-content/uploads/2026/06/9781962770651.jpg?cap=old",
        provider: "archipelago_books_official_store",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: nil
      })

    large_body = large_jpeg_bytes(34_712_921)

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: [cover.source_url],
        fetch: fn
          "https://archipelagobooks.org/wp-content/uploads/2026/06/9781962770651.jpg?cap=old" ->
            large_body
        end,
        thumbnailer: fn _cache_path, thumbnail_path ->
          File.write!(thumbnail_path, "fake thumbnail bytes")
          {:ok, thumbnail_path}
        end
      )

    assert %{cached: 1, skipped: 0, failed: 0, assets: [cached_asset]} = summary
    assert File.read!(cached_asset.cached_file_path) == large_body
    assert File.read!(cached_asset.thumbnail_file_path) == "fake thumbnail bytes"
  end

  test "default cover fetch streams and halts oversized responses before materializing the full body",
       %{
         admin: admin
       } do
    cache_root = unique_cache_root("streamed-oversized-body")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    max_body_size = byte_size(png_bytes())
    parent = self()

    streaming =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/streamed-oversized-body.png",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: nil
      })

    expected_cache_path = Covers.cache_path(streaming, cache_root)

    chunks = [png_bytes(), "x", String.duplicate("unread", 2_000)]

    adapter = fn request ->
      response = Req.Response.new(status: 200, headers: [{"content-type", "image/png"}])

      case request.into do
        into when is_function(into, 2) ->
          {request, response, delivered_chunks, delivered_bytes} =
            Enum.reduce_while(chunks, {request, response, 0, 0}, fn chunk,
                                                                    {request, response, count,
                                                                     bytes} ->
              delivered_chunks = count + 1
              delivered_bytes = bytes + byte_size(chunk)

              case into.({:data, chunk}, {request, response}) do
                {:cont, {request, response}} ->
                  {:cont, {request, response, delivered_chunks, delivered_bytes}}

                {:halt, {request, response}} ->
                  {:halt, {request, response, delivered_chunks, delivered_bytes}}
              end
            end)

          send(parent, {:bounded_stream_adapter, delivered_chunks, delivered_bytes})
          {request, response}

        _not_streaming ->
          body = IO.iodata_to_binary(chunks)
          send(parent, {:bounded_stream_adapter, length(chunks), byte_size(body)})
          {request, %{response | body: body}}
      end
    end

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://covers.example.test/streamed-oversized-body.png"],
        max_body_size: max_body_size,
        req_options: [adapter: adapter],
        thumbnailer: fn _cache_path, _thumbnail_path -> nil end
      )

    assert %{cached: 0, skipped: 0, failed: 1, failures: [%{reason: reason}]} = summary
    assert reason =~ "body size"
    assert reason =~ "exceeds"
    assert_received {:bounded_stream_adapter, 2, received_bytes}
    assert received_bytes == max_body_size + 1
    refute File.exists?(expected_cache_path)
  end

  test "cover cache task rejects invalid content type responses before writing cache files", %{
    admin: admin
  } do
    cache_root = unique_cache_root("invalid-content-type")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    invalid =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/not-a-cover.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: nil
      })

    expected_cache_path = Covers.cache_path(invalid, cache_root)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, "<html><body>not a raster cover</body></html>")
    end

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://covers.example.test/not-a-cover.jpg"],
        req_options: [plug: plug],
        thumbnailer: fn _cache_path, _thumbnail_path -> nil end
      )

    assert %{cached: 0, skipped: 0, failed: 1, failures: [%{reason: reason}]} = summary
    assert reason =~ "content-type"
    assert reason =~ "image/"
    refute File.exists?(expected_cache_path)
  end

  test "cover cache task validates raster magic bytes before writing cache files", %{
    admin: admin
  } do
    cache_root = unique_cache_root("invalid-magic-bytes")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    invalid =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/not-a-real-jpeg.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: nil
      })

    expected_cache_path = Covers.cache_path(invalid, cache_root)

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://covers.example.test/not-a-real-jpeg.jpg"],
        fetch: fn "https://covers.example.test/not-a-real-jpeg.jpg" ->
          "%PDF-1.7\nnot a raster cover"
        end,
        thumbnailer: fn _cache_path, _thumbnail_path -> nil end
      )

    assert %{cached: 0, skipped: 0, failed: 1, failures: [%{reason: reason}]} = summary
    assert reason =~ "magic bytes"
    assert reason =~ "raster"
    refute File.exists?(expected_cache_path)
  end

  test "cover cache task rejects allowed raster content-type mismatch before writing cache files",
       %{
         admin: admin
       } do
    cache_root = unique_cache_root("content-type-mismatch")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    mismatched =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/mismatched-raster.png",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: nil
      })

    expected_cache_path = Covers.cache_path(mismatched, cache_root)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.resp(200, jpeg_bytes())
    end

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://covers.example.test/mismatched-raster.png"],
        req_options: [plug: plug],
        thumbnailer: fn _cache_path, _thumbnail_path -> nil end
      )

    assert %{cached: 0, skipped: 0, failed: 1, failures: [%{reason: reason}]} = summary
    assert reason =~ "content-type"
    assert reason =~ "does not match"
    refute File.exists?(expected_cache_path)
  end

  test "cover cache task rejects symlinked cache-root path components before writing outside cache",
       %{
         admin: admin
       } do
    symlink_parent = unique_cache_root("symlink-root")

    outside_dir =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-cover-cache-outside-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(symlink_parent)
    File.mkdir_p!(outside_dir)

    symlink_cache_root = Path.join(symlink_parent, "linked-cache-root")
    :ok = File.ln_s(outside_dir, symlink_cache_root)

    on_exit(fn ->
      File.rm_rf!(symlink_parent)
      File.rm_rf!(outside_dir)
    end)

    symlinked_root =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/symlink-root.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: nil
      })

    expected_outside_path = Covers.cache_path(symlinked_root, symlink_cache_root)

    assert_raise ArgumentError, ~r/symlink|cache_root/i, fn ->
      Covers.cache_public_covers!(
        cache_root: symlink_cache_root,
        source_urls: ["https://covers.example.test/symlink-root.jpg"],
        fetch: fn "https://covers.example.test/symlink-root.jpg" -> jpeg_bytes() end,
        thumbnailer: fn _cache_path, _thumbnail_path -> nil end
      )
    end

    refute File.exists?(expected_outside_path)
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

  test "cover cache task does not write thumbnails through symlinked output paths", %{
    admin: admin
  } do
    cache_root = unique_cache_root("thumbnail-symlink")

    outside_dir =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-thumbnail-outside-#{System.unique_integer([:positive])}"
      )

    outside_path = Path.join(outside_dir, "outside-thumb.jpg")

    File.mkdir_p!(cache_root)
    File.mkdir_p!(outside_dir)

    on_exit(fn ->
      File.rm_rf!(cache_root)
      File.rm_rf!(outside_dir)
    end)

    cacheable =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/thumbnail-symlink.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: nil
      })

    thumbnail_path = Covers.thumbnail_path(cacheable, cache_root)
    :ok = File.ln_s(outside_path, thumbnail_path)

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://covers.example.test/thumbnail-symlink.jpg"],
        fetch: fn "https://covers.example.test/thumbnail-symlink.jpg" -> jpeg_bytes() end,
        thumbnailer: fn _source_path, ^thumbnail_path ->
          File.write!(thumbnail_path, "thumbnail written through symlink")
          {:ok, thumbnail_path}
        end
      )

    assert %{cached: 1, skipped: 0, failed: 0, assets: [cached_asset]} = summary
    assert File.read!(cached_asset.cached_file_path) == jpeg_bytes()
    assert cached_asset.thumbnail_file_path == nil
    refute File.exists?(outside_path)
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
          fetch: fn "https://covers.example.test/hung-thumbnail.jpg" -> jpeg_bytes() end,
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
    assert File.read!(cached_asset.cached_file_path) == jpeg_bytes()
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
        fetch: fn "https://covers.example.test/stale-cache.jpg" -> jpeg_bytes() end
      )

    assert %{cached: 1, skipped: 0, assets: [refreshed]} = summary
    assert File.read!(refreshed.cached_file_path) == jpeg_bytes()
    assert Covers.public_cover_asset?(refreshed)
  end

  test "new directions link-only cover falls back without remote public image dependency",
       %{
         admin: admin,
         edition: edition
       } do
    link_only =
      cover_asset!(admin, %{
        source_url: "https://cdn.sanity.io/images/new-directions-link-only.jpg",
        provider: "new_directions_official_site",
        rights_basis: "provider_link_allowed",
        cache_policy: "link_only",
        cached_file_path: nil,
        thumbnail_file_path: nil
      })

    assignment!(admin, edition, link_only)

    refute Covers.public_cover_asset?(link_only)
    refute Covers.public_cover_provenance_valid?(link_only)

    assert Covers.public_cover_rejection_reason(link_only) ==
             "public cover display requires cache_allowed with a validated local cached file"

    assert Covers.public_cover_for_edition(edition.id) == Covers.fallback_cover()
  end

  test "cover cache task caches new directions covers when provenance and host are valid", %{
    admin: admin
  } do
    cache_root = unique_cache_root("new-directions-cache")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    _new_directions =
      cover_asset!(admin, %{
        source_url: "https://cdn.sanity.io/images/new-directions-cache-attempt.jpg",
        provider: "new_directions_official_site",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed"
      })

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: ["https://cdn.sanity.io/images/new-directions-cache-attempt.jpg"],
        fetch: fn "https://cdn.sanity.io/images/new-directions-cache-attempt.jpg" ->
          jpeg_bytes()
        end,
        thumbnailer: fn _cache_path, thumbnail_path ->
          File.write!(thumbnail_path, "new directions thumbnail bytes")
          {:ok, thumbnail_path}
        end
      )

    assert %{cached: 1, skipped: 0, failed: 0, assets: [cached_asset]} = summary
    assert String.starts_with?(cached_asset.cached_file_path, cache_root)
    assert Covers.public_cover_asset?(cached_asset)
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

  test "default cover fetch percent-encodes unicode source paths", %{admin: admin} do
    cache_root = unique_cache_root("unicode-source-path")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    unicode_url = "https://covers.example.test/covers/LOVE-Ørstavik-cover.jpg"

    _asset =
      cover_asset!(admin, %{
        source_url: unicode_url,
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed"
      })

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.resp(200, jpeg_bytes())
    end

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: [unicode_url],
        req_options: [plug: plug],
        thumbnailer: fn _cache_path, _thumbnail_path -> nil end
      )

    assert %{cached: 1, skipped: 0, failed: 0, assets: [cached_asset]} = summary
    assert Covers.public_cover_asset?(cached_asset)
  end

  test "default cover fetch follows only openlibrary archive cover redirects", %{admin: admin} do
    cache_root = unique_cache_root("openlibrary-archive-redirect")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    source_url = "https://covers.openlibrary.org/b/isbn/9790000000001-L.jpg?default=false"

    _asset =
      cover_asset!(admin, %{
        source_url: source_url,
        provider: "dalkey_archive_official_store",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed"
      })

    adapter = fn request ->
      uri = URI.parse(to_string(request.url))

      response =
        cond do
          uri.host == "covers.openlibrary.org" ->
            Req.Response.new(
              status: 302,
              headers: [
                {"location",
                 "https://ia800603.us.archive.org/view_archive.php?archive=/covers.zip&file=cover.jpg"}
              ]
            )

          uri.host == "ia800603.us.archive.org" ->
            response =
              Req.Response.new(
                status: 200,
                headers: [{"content-type", "image/jpeg"}]
              )

            case request.into do
              into when is_function(into, 2) ->
                {:cont, {_request, streamed_response}} =
                  into.({:data, jpeg_bytes()}, {request, response})

                streamed_response

              _not_streaming ->
                %{response | body: jpeg_bytes()}
            end

          true ->
            Req.Response.new(status: 500, body: "unexpected host")
        end

      {request, response}
    end

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: [source_url],
        req_options: [adapter: adapter],
        thumbnailer: fn _cache_path, _thumbnail_path -> nil end
      )

    assert %{cached: 1, skipped: 0, failed: 0, assets: [cached_asset]} = summary
    assert Covers.public_cover_asset?(cached_asset)
  end

  test "default cover fetch follows squarespace static cover redirects", %{admin: admin} do
    cache_root = unique_cache_root("squarespace-cover-redirect")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    source_url =
      "https://static1.squarespace.com/static/site/collection/item/cover/"

    _asset =
      cover_asset!(admin, %{
        source_url: source_url,
        provider: "transit_books_official_site",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed"
      })

    adapter = fn request ->
      uri = URI.parse(to_string(request.url))

      response =
        cond do
          uri.host == "static1.squarespace.com" ->
            Req.Response.new(
              status: 302,
              headers: [{"location", "https://images.squarespace-cdn.com/content/cover.jpg"}]
            )

          uri.host == "images.squarespace-cdn.com" ->
            response =
              Req.Response.new(
                status: 200,
                headers: [{"content-type", "image/jpeg"}]
              )

            case request.into do
              into when is_function(into, 2) ->
                {:cont, {_request, streamed_response}} =
                  into.({:data, jpeg_bytes()}, {request, response})

                streamed_response

              _not_streaming ->
                %{response | body: jpeg_bytes()}
            end

          true ->
            Req.Response.new(status: 500, body: "unexpected host")
        end

      {request, response}
    end

    summary =
      Covers.cache_public_covers!(
        cache_root: cache_root,
        source_urls: [source_url],
        req_options: [adapter: adapter],
        thumbnailer: fn _cache_path, _thumbnail_path -> nil end
      )

    assert %{cached: 1, skipped: 0, failed: 0, assets: [cached_asset]} = summary
    assert Covers.public_cover_asset?(cached_asset)
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

  defp unique_cache_root(prefix) do
    Path.join(
      "priv/static/covers/cache",
      "#{prefix}-#{System.unique_integer([:positive])}"
    )
  end

  defp png_bytes do
    <<0x89, ?P, ?N, ?G, 0x0D, 0x0A, 0x1A, 0x0A, "fixture-png-raster-bytes">>
  end

  defp jpeg_bytes do
    <<0xFF, 0xD8, 0xFF, 0xE0, "fixture-jpeg-raster-bytes", 0xFF, 0xD9>>
  end

  defp large_jpeg_bytes(size) when is_integer(size) and size > 0 do
    header = jpeg_bytes()
    padding = size - byte_size(header)
    header <> String.duplicate("x", padding)
  end

  defp alternate_jpeg_bytes do
    <<0xFF, 0xD8, 0xFF, 0xE1, "new-fixture-jpeg-raster-bytes", 0xFF, 0xD9>>
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
