defmodule HiraethWeb.AdminSessionController do
  use HiraethWeb, :controller

  alias Hiraeth.Accounts
  alias HiraethWeb.AdminAuth

  def create(conn, %{"token" => token}) do
    case Accounts.consume_invite(token) do
      {:ok, session} ->
        conn
        |> AdminAuth.log_in_admin(session.raw_session_token)
        |> put_flash(:info, "Admin session started.")
        |> redirect(to: ~p"/admin/ingestion")

      _error ->
        conn
        |> put_flash(:error, "Admin invite is expired or already used.")
        |> redirect(to: ~p"/")
    end
  end
end
