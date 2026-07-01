defmodule HiraethWeb.HealthControllerTest do
  use HiraethWeb.ConnCase, async: false

  setup do
    original_readiness = Application.get_env(:hiraeth, :readiness)
    original_sidecar_required = System.get_env("HIRAETH_READY_SIDECAR_REQUIRED")
    original_sidecar_url = System.get_env("SCRAPLING_SIDECAR_URL")

    on_exit(fn ->
      restore_env(:readiness, original_readiness)
      restore_system_env("HIRAETH_READY_SIDECAR_REQUIRED", original_sidecar_required)
      restore_system_env("SCRAPLING_SIDECAR_URL", original_sidecar_url)
    end)

    :ok
  end

  test "GET /health returns ok without checking database readiness", %{conn: conn} do
    Application.put_env(:hiraeth, :readiness, repo_check: fn -> raise "database unavailable" end)

    conn = get(conn, ~p"/health")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /ready returns ready when database is reachable and sidecar check is disabled", %{
    conn: conn
  } do
    Application.put_env(:hiraeth, :readiness, repo_check: fn -> :ok end)

    conn = get(conn, ~p"/ready")

    assert json_response(conn, 200) == %{
             "status" => "ready",
             "checks" => %{"database" => "ok", "sidecar" => "disabled"}
           }
  end

  test "GET /ready returns a safe failure when database readiness fails", %{conn: conn} do
    Application.put_env(:hiraeth, :readiness, repo_check: fn -> :unavailable end)

    conn = get(conn, ~p"/ready")
    body = json_response(conn, 503)

    assert body == %{
             "status" => "unready",
             "checks" => %{"database" => "unavailable", "sidecar" => "disabled"}
           }

    refute inspect(body) =~ "password"
    refute inspect(body) =~ "stack"
  end

  test "GET /ready returns a safe failure when required sidecar readiness fails", %{conn: conn} do
    System.put_env("SCRAPLING_SIDECAR_URL", "http://127.0.0.1:1")

    Application.put_env(:hiraeth, :readiness,
      repo_check: fn -> :ok end,
      require_sidecar: true,
      sidecar_timeout: 10
    )

    conn = get(conn, ~p"/ready")
    body = json_response(conn, 503)

    assert body == %{
             "status" => "unready",
             "checks" => %{"database" => "ok", "sidecar" => "unavailable"}
           }

    refute inspect(body) =~ "http://"
    refute inspect(body) =~ "password"
    refute inspect(body) =~ "stack"
  end

  test "router keeps health endpoints narrow and does not expose broad api routes" do
    paths = HiraethWeb.Router.__routes__() |> Enum.map(& &1.path)

    assert "/health" in paths
    assert "/ready" in paths
    refute Enum.any?(paths, &String.starts_with?(&1, "/api"))
  end

  defp restore_env(key, nil), do: Application.delete_env(:hiraeth, key)
  defp restore_env(key, value), do: Application.put_env(:hiraeth, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
