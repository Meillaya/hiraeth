defmodule HiraethWeb.AdminAuth do
  @moduledoc """
  Phoenix session and LiveView hooks for the admin-only ingestion surface.
  """

  import Plug.Conn, except: [assign: 3]

  alias Hiraeth.Accounts

  def init(action), do: action

  def call(conn, :require_admin), do: require_admin(conn, [])
  def call(conn, :fetch_current_admin), do: fetch_current_admin(conn, [])

  def fetch_current_admin(conn, _opts) do
    Plug.Conn.assign(conn, :current_admin_user, current_admin_from_conn(conn))
  end

  def require_admin(conn, _opts) do
    case current_admin_from_conn(conn) do
      nil ->
        conn
        |> Phoenix.Controller.put_flash(:error, "You need admin access to continue.")
        |> Phoenix.Controller.redirect(to: "/")
        |> halt()

      admin_user ->
        Plug.Conn.assign(conn, :current_admin_user, admin_user)
    end
  end

  def log_in_admin(conn, raw_session_token) when is_binary(raw_session_token) do
    conn
    |> configure_session(renew: true)
    |> put_session(:admin_session_token, raw_session_token)
  end

  def log_out_admin(conn) do
    conn
    |> configure_session(drop: true)
  end

  def on_mount(:require_admin, _params, session, socket) do
    case Accounts.admin_from_session_token(session["admin_session_token"]) do
      {:ok, admin_user} ->
        {:cont,
         socket
         |> Phoenix.Component.assign(:current_admin_user, admin_user)
         |> Phoenix.Component.assign(:current_admin_actor, Accounts.ingestion_actor(admin_user))}

      _error ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "You need admin access to continue.")
         |> Phoenix.LiveView.redirect(to: "/")}
    end
  end

  defp current_admin_from_conn(conn) do
    case Accounts.admin_from_session_token(get_session(conn, :admin_session_token)) do
      {:ok, admin_user} -> admin_user
      _error -> nil
    end
  end
end
