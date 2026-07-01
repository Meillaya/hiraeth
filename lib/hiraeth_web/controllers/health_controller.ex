defmodule HiraethWeb.HealthController do
  use HiraethWeb, :controller

  @default_sidecar_timeout 500

  def health(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def ready(conn, _params) do
    checks = %{
      database: database_status(),
      sidecar: sidecar_status()
    }

    if Enum.all?(checks, fn {_name, status} -> status in [:ok, :disabled] end) do
      json(conn, %{status: "ready", checks: stringify_checks(checks)})
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "unready", checks: stringify_checks(checks)})
    end
  end

  defp database_status do
    repo_check = Keyword.get(readiness_config(), :repo_check, &default_repo_check/0)

    case repo_check.() do
      :ok -> :ok
      _ -> :unavailable
    end
  rescue
    _exception -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp default_repo_check do
    case Ecto.Adapters.SQL.query(Hiraeth.Repo, "SELECT 1", [], timeout: 1_000) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :unavailable
    end
  end

  defp sidecar_status do
    if sidecar_required?() do
      check_required_sidecar()
    else
      :disabled
    end
  end

  defp check_required_sidecar do
    timeout = Keyword.get(readiness_config(), :sidecar_timeout, @default_sidecar_timeout)
    base_url = sidecar_base_url()

    case Req.get("#{base_url}/health/", receive_timeout: timeout, retry: false) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      _other -> :unavailable
    end
  rescue
    _exception -> :unavailable
  end

  defp sidecar_required? do
    Keyword.get(readiness_config(), :require_sidecar, false) or
      System.get_env("HIRAETH_READY_SIDECAR_REQUIRED") in ["1", "true", "TRUE"]
  end

  defp sidecar_base_url do
    System.get_env("SCRAPLING_SIDECAR_URL") ||
      get_in(Application.get_env(:hiraeth, :scrapling_sidecar, []), [:base_url]) ||
      "http://localhost:8000"
  end

  defp readiness_config do
    Application.get_env(:hiraeth, :readiness, [])
  end

  defp stringify_checks(checks) do
    Map.new(checks, fn {name, status} -> {name, Atom.to_string(status)} end)
  end
end
