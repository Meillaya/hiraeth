defmodule Hiraeth.Ingestion.CoverPipelineTest do
  use ExUnit.Case, async: true

  alias Hiraeth.Ingestion.CoverPipeline

  @fixture_cover_urls [
    "https://covers.example.test/cover1.jpg",
    "https://covers.example.test/cover2.jpg",
    "https://covers.example.test/ok.jpg",
    "https://covers.example.test/fail.jpg",
    "https://covers.example.test/rate-1.jpg",
    "https://covers.example.test/rate-2.jpg",
    "http://covers.example.test/insecure.jpg",
    "https://evil.example.test/malicious.jpg"
  ]

  setup do
    cleanup_fixture_covers!()
    on_exit(&cleanup_fixture_covers!/0)
    :ok
  end

  test "all covers download successfully" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.resp(200, jpeg_bytes())
    end

    cover_urls = [
      %{
        source_url: "https://covers.example.test/cover1.jpg",
        provider: "fixture-covers",
        rights_basis: "local_cache_permitted",
        attribution_text: "Test 1"
      },
      %{
        source_url: "https://covers.example.test/cover2.jpg",
        provider: "fixture-covers",
        rights_basis: "local_cache_permitted",
        attribution_text: "Test 2"
      }
    ]

    provider_config = %{
      max_concurrency: 2,
      req_options: [plug: plug],
      thumbnailer: fn _source_path, thumbnail_path ->
        File.write!(thumbnail_path, "fake thumbnail bytes")
        {:ok, thumbnail_path}
      end
    }

    assert {:ok, cover_paths} = CoverPipeline.download_and_cache!(cover_urls, provider_config)

    assert map_size(cover_paths) == 2

    for cover <- cover_urls do
      assert %{cached_file_path: cached_path, thumbnail_file_path: thumb_path} =
               cover_paths[cover.source_url]

      assert File.exists?(cached_path)
      assert File.read!(cached_path) == jpeg_bytes()
      assert File.exists?(thumb_path)
      assert File.read!(thumb_path) == "fake thumbnail bytes"
    end
  end

  test "cover-specific manifest hosts are available inside async cache workers" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.resp(200, jpeg_bytes())
    end

    cover_urls = [
      %{
        source_url: "https://manifest-cdn.example.test/cover.jpg",
        provider: "manifest-provider",
        rights_basis: "local_cache_permitted",
        attribution_text: "Manifest cover",
        allowed_cover_hosts: ["manifest-cdn.example.test"]
      }
    ]

    provider_config = %{
      max_concurrency: 1,
      req_options: [plug: plug],
      thumbnailer: fn _source_path, thumbnail_path ->
        File.write!(thumbnail_path, "fake thumbnail bytes")
        {:ok, thumbnail_path}
      end
    }

    assert {:ok, cover_paths} = CoverPipeline.download_and_cache!(cover_urls, provider_config)
    assert Map.has_key?(cover_paths, "https://manifest-cdn.example.test/cover.jpg")
  end

  test "cover redirects must stay within cover-specific manifest hosts" do
    parent = self()

    adapter = fn request ->
      uri = URI.parse(to_string(request.url))
      send(parent, {:cover_request, uri.host})

      response =
        if uri.host == "static1.squarespace.com" do
          Req.Response.new(
            status: 302,
            headers: [{"location", "https://images.squarespace-cdn.com/content/cover.jpg"}]
          )
        else
          Req.Response.new(status: 500, body: "unexpected redirected request")
        end

      {request, response}
    end

    cover_urls = [
      %{
        source_url: "https://static1.squarespace.com/static/site/cover/",
        provider: "manifest-provider",
        rights_basis: "local_cache_permitted",
        attribution_text: "Manifest cover",
        allowed_cover_hosts: ["static1.squarespace.com"]
      }
    ]

    provider_config = %{
      max_concurrency: 1,
      req_options: [adapter: adapter],
      thumbnailer: fn _source_path, thumbnail_path ->
        File.write!(thumbnail_path, "fake thumbnail bytes")
        {:ok, thumbnail_path}
      end
    }

    assert {:error, [%{reason: reason}]} =
             CoverPipeline.download_and_cache!(cover_urls, provider_config)

    assert reason =~ "status 302"
    assert_received {:cover_request, "static1.squarespace.com"}
    refute_receive {:cover_request, "images.squarespace-cdn.com"}
  end

  test "one cover fails returns error and cleans up all covers" do
    plug = fn conn ->
      if conn.request_path == "/fail.jpg" do
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(500, "server error")
      else
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.resp(200, jpeg_bytes())
      end
    end

    cover_urls = [
      %{
        source_url: "https://covers.example.test/ok.jpg",
        provider: "fixture-covers",
        rights_basis: "local_cache_permitted",
        attribution_text: "Test"
      },
      %{
        source_url: "https://covers.example.test/fail.jpg",
        provider: "fixture-covers",
        rights_basis: "local_cache_permitted",
        attribution_text: "Test"
      }
    ]

    provider_config = %{
      max_concurrency: 2,
      req_options: [plug: plug, retry: false],
      thumbnailer: fn _source_path, thumbnail_path ->
        File.write!(thumbnail_path, "fake thumbnail bytes")
        {:ok, thumbnail_path}
      end
    }

    assert {:error, failed_covers} =
             CoverPipeline.download_and_cache!(cover_urls, provider_config)

    assert length(failed_covers) == 1

    assert %{source_url: "https://covers.example.test/fail.jpg", reason: reason} =
             hd(failed_covers)

    assert reason =~ "status 500"

    {ok_path, ok_thumbnail_path} = fixture_cache_paths("https://covers.example.test/ok.jpg")

    refute File.exists?(ok_path)
    refute File.exists?(ok_thumbnail_path)
  end

  test "rate limiting respected" do
    plug = fn conn ->
      Process.sleep(30)

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.resp(200, jpeg_bytes())
    end

    cover_urls = [
      %{
        source_url: "https://covers.example.test/rate-1.jpg",
        provider: "fixture-covers",
        rights_basis: "local_cache_permitted",
        attribution_text: "Test"
      },
      %{
        source_url: "https://covers.example.test/rate-2.jpg",
        provider: "fixture-covers",
        rights_basis: "local_cache_permitted",
        attribution_text: "Test"
      }
    ]

    provider_config_serial = %{
      max_concurrency: 1,
      req_options: [plug: plug],
      thumbnailer: fn _source_path, thumbnail_path ->
        File.write!(thumbnail_path, "fake thumbnail bytes")
        {:ok, thumbnail_path}
      end
    }

    {time_serial, {:ok, paths_serial}} =
      :timer.tc(fn ->
        CoverPipeline.download_and_cache!(cover_urls, provider_config_serial)
      end)

    # Clean up for parallel run
    Enum.each(paths_serial, fn {_url, %{cached_file_path: path, thumbnail_file_path: thumb}} ->
      File.rm(path)
      File.rm(thumb)
    end)

    provider_config_parallel = %{
      max_concurrency: 2,
      req_options: [plug: plug],
      thumbnailer: fn _source_path, thumbnail_path ->
        File.write!(thumbnail_path, "fake thumbnail bytes")
        {:ok, thumbnail_path}
      end
    }

    {time_parallel, {:ok, _paths_parallel}} =
      :timer.tc(fn ->
        CoverPipeline.download_and_cache!(cover_urls, provider_config_parallel)
      end)

    # Serial should take roughly 2x as long as parallel
    assert time_serial > time_parallel
  end

  test "non-HTTPS URL rejected" do
    cover_urls = [
      %{
        source_url: "http://covers.example.test/insecure.jpg",
        provider: "fixture-covers",
        rights_basis: "local_cache_permitted",
        attribution_text: "Test"
      }
    ]

    provider_config = %{max_concurrency: 1}

    assert {:error, [%{source_url: "http://covers.example.test/insecure.jpg", reason: reason}]} =
             CoverPipeline.download_and_cache!(cover_urls, provider_config)

    assert reason =~ "HTTPS"
  end

  test "non-allowlisted host rejected" do
    cover_urls = [
      %{
        source_url: "https://evil.example.test/malicious.jpg",
        provider: "fixture-covers",
        rights_basis: "local_cache_permitted",
        attribution_text: "Test"
      }
    ]

    provider_config = %{max_concurrency: 1}

    assert {:error, [%{source_url: "https://evil.example.test/malicious.jpg", reason: reason}]} =
             CoverPipeline.download_and_cache!(cover_urls, provider_config)

    assert reason =~ "allowlisted"
  end

  defp jpeg_bytes do
    <<0xFF, 0xD8, 0xFF, 0xE0, "fixture-jpeg-raster-bytes", 0xFF, 0xD9>>
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp cleanup_fixture_covers! do
    Enum.each(@fixture_cover_urls, fn url ->
      {cache_path, thumbnail_path} = fixture_cache_paths(url)

      File.rm(cache_path)
      File.rm(thumbnail_path)
    end)
  end

  defp fixture_cache_paths(url) do
    cache_root = Path.expand(Path.join(["priv", "static", "covers", "cache"]))
    digest = sha256(url)

    {
      Path.join(cache_root, "#{digest}.jpg"),
      Path.join(cache_root, "#{digest}-thumb.jpg")
    }
  end
end
