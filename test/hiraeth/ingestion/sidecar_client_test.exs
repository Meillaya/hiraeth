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

    test "returns error when sidecar reports error status" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"provider":"deep_vellum","status":"error: something","records":[]})
        )
      end

      assert {:error, "error: something"} =
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

    test "returns error when sidecar reports error status" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"provider":"deep_vellum","status":"error: something","records":[]})
        )
      end

      assert {:error, "error: something"} =
               SidecarClient.scrape(
                 %{provider: "deep_vellum", config: %{}},
                 req_options: [plug: plug]
               )
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
