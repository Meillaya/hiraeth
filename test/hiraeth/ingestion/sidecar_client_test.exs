defmodule Hiraeth.Ingestion.SidecarClientTest do
  use ExUnit.Case, async: true

  alias Hiraeth.Ingestion.SidecarClient

  describe "health/0" do
    test "returns ok when sidecar is healthy" do
      plug = fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/health/"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status":"ok","scrapling":true}))
      end

      assert {:ok, %{status: "ok", scrapling: true}} =
               SidecarClient.health(req_options: [plug: plug])
    end

    test "returns error when sidecar returns non-200" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, ~s({"error":"service unavailable"}))
      end

      assert {:error, "sidecar health check failed with status 503"} =
               SidecarClient.health(req_options: [plug: plug])
    end

    test "returns error on timeout" do
      Req.Test.stub(:timeout_sidecar, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, "timeout"} =
               SidecarClient.health(req_options: [plug: {Req.Test, :timeout_sidecar}])
    end
  end

  describe "fetch/1" do
    test "returns records on success" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/fetch/"

        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "provider" => "deep_vellum",
                 "config" => %{"url" => "https://example.com"}
               }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"provider":"deep_vellum","status":"ok","records":[{"title":"Book 1"}]})
        )
      end

      assert {:ok, %{records: [%{"title" => "Book 1"}]}} =
               SidecarClient.fetch(
                 %{provider: "deep_vellum", config: %{url: "https://example.com"}},
                 req_options: [plug: plug]
               )
    end

    test "returns error when sidecar returns non-200" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"error":"internal server error"}))
      end

      assert {:error, "sidecar fetch failed with status 500"} =
               SidecarClient.fetch(
                 %{provider: "deep_vellum", config: %{}},
                 req_options: [plug: plug]
               )
    end

    test "maps typed sidecar error responses to tagged errors" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, ~s({"detail":{"code":"rate_limited","message":"slow down"}}))
      end

      assert {:error, {:rate_limited, "slow down"}} =
               SidecarClient.fetch(
                 %{provider: "deep_vellum", config: %{}},
                 req_options: [plug: plug]
               )
    end
  end

  describe "scrape/1" do
    test "returns records on success" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/scrape/"

        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "provider" => "deep_vellum",
                 "config" => %{"url" => "https://example.com"}
               }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"provider":"deep_vellum","status":"ok","records":[{"title":"Book 1"}]})
        )
      end

      assert {:ok, %{records: [%{"title" => "Book 1"}]}} =
               SidecarClient.scrape(
                 %{provider: "deep_vellum", config: %{url: "https://example.com"}},
                 req_options: [plug: plug]
               )
    end

    test "returns error when sidecar returns non-200" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"error":"internal server error"}))
      end

      assert {:error, "sidecar scrape failed with status 500"} =
               SidecarClient.scrape(
                 %{provider: "deep_vellum", config: %{}},
                 req_options: [plug: plug]
               )
    end

    test "maps typed scrape errors to tagged errors" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(422, ~s({"detail":{"code":"parse_failed","message":"selector broke"}}))
      end

      assert {:error, {:parse_failed, "selector broke"}} =
               SidecarClient.scrape(
                 %{provider: "deep_vellum", config: %{}},
                 req_options: [plug: plug]
               )
    end
  end

  describe "detail/3" do
    test "posts source URL and vendor to detail endpoint and returns enrichment" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/scrape/detail"

        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "url" => "https://store.deepvellum.org/products/rilke-shake",
                 "vendor" => "deep_vellum_official_store"
               }

        Req.Test.json(conn, %{
          "vendor" => "deep_vellum_official_store",
          "source_uri" => "https://store.deepvellum.org/products/rilke-shake",
          "contributors" => [%{"name" => "Angélica Freitas", "role" => "author"}],
          "isbn_13" => "9781939419545",
          "published_on" => "2015-03-24",
          "cover" => %{"source_url" => "https://cdn.shopify.com/deep-vellum/rilke.jpg"},
          "description" => "detail copy"
        })
      end

      assert {:ok,
              %{
                "contributors" => [%{"name" => "Angélica Freitas", "role" => "author"}],
                "cover" => %{"source_url" => "https://cdn.shopify.com/deep-vellum/rilke.jpg"},
                "isbn_13" => "9781939419545"
              }} =
               SidecarClient.detail(
                 "https://store.deepvellum.org/products/rilke-shake",
                 "deep_vellum_official_store",
                 req_options: [plug: plug]
               )
    end

    test "includes configured max_bytes in detail endpoint request body" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/scrape/detail"

        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "url" => "https://store.deepvellum.org/products/rilke-shake",
                 "vendor" => "deep_vellum_official_store",
                 "max_bytes" => 524_288
               }

        Req.Test.json(conn, %{
          "vendor" => "deep_vellum_official_store",
          "source_uri" => "https://store.deepvellum.org/products/rilke-shake",
          "contributors" => [],
          "cover" => %{},
          "description" => nil
        })
      end

      assert {:ok, _detail} =
               SidecarClient.detail(
                 "https://store.deepvellum.org/products/rilke-shake",
                 "deep_vellum_official_store",
                 max_bytes: 524_288,
                 req_options: [plug: plug]
               )
    end

    test "maps typed detail errors to tagged errors" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          422,
          ~s({"detail":{"code":"invalid_host","message":"non-allowlisted host"}})
        )
      end

      assert {:error, {:invalid_host, "non-allowlisted host"}} =
               SidecarClient.detail(
                 "https://evil.example/books/1",
                 "deep_vellum_official_store",
                 req_options: [plug: plug]
               )
    end

    test "returns error on detail timeout" do
      Req.Test.stub(:detail_timeout_sidecar, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, "timeout"} =
               SidecarClient.detail(
                 "https://store.deepvellum.org/products/rilke-shake",
                 "deep_vellum_official_store",
                 req_options: [plug: {Req.Test, :detail_timeout_sidecar}, retry: false]
               )
    end

    test "bounds transient detail retries to three retry attempts" do
      parent = self()

      Req.Test.expect(:detail_retry_sidecar, 4, fn conn ->
        send(parent, :detail_attempt)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"error":"still down"}))
      end)

      assert {:error, "sidecar detail failed with status 500"} =
               SidecarClient.detail(
                 "https://store.deepvellum.org/products/rilke-shake",
                 "deep_vellum_official_store",
                 req_options: [
                   plug: {Req.Test, :detail_retry_sidecar},
                   retry_delay: fn _retry_count -> 0 end,
                   retry_log_level: false
                 ]
               )

      for _ <- 1..4 do
        assert_receive :detail_attempt
      end

      refute_receive :detail_attempt
    end
  end

  describe "sidecar down" do
    test "health returns error when sidecar is unreachable" do
      Req.Test.stub(:down_sidecar, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, "connection refused"} =
               SidecarClient.health(req_options: [plug: {Req.Test, :down_sidecar}])
    end
  end
end
