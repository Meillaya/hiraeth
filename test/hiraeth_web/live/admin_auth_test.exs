defmodule HiraethWeb.AdminAuthTest do
  use HiraethWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hiraeth.Accounts

  test "/admin redirects anonymous users to the public home page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
  end

  test "/admin/ingestion denies anonymous users", %{conn: conn} do
    conn = get(conn, ~p"/admin/ingestion")
    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "admin access"
  end

  test "one-time invite link creates signed admin session and permits protected LiveView", %{
    conn: conn
  } do
    {:ok, invite} =
      Accounts.invite_admin(%{email: "web-owner@example.test", role: "owner", expires_in: "15m"})

    conn = get(conn, ~p"/admin/session/#{invite.raw_token}")
    assert redirected_to(conn) == ~p"/admin/ingestion"
    assert get_session(conn, :admin_session_token)

    {:ok, _view, html} = live(recycle(conn), ~p"/admin/ingestion")
    assert html =~ "Provider registry and run timeline"
    assert html =~ "web-owner@example.test"

    second = get(build_conn(), ~p"/admin/session/#{invite.raw_token}")
    assert redirected_to(second) == ~p"/"
    assert Phoenix.Flash.get(second.assigns.flash, :error) =~ "expired or already used"
  end

  test "disabled admin session is denied", %{conn: conn} do
    {:ok, invite} =
      Accounts.invite_admin(%{
        email: "web-disabled@example.test",
        role: "owner",
        expires_in: "15m"
      })

    {:ok, session} = Accounts.consume_invite(invite.raw_token)

    session.admin_user
    |> Ash.Changeset.for_update(:disable, %{})
    |> Ash.update!(actor: Accounts.system_actor())

    conn = init_test_session(conn, admin_session_token: session.raw_session_token)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/ingestion")
  end

  test "router has no public registration profile or social routes" do
    paths = HiraethWeb.Router.__routes__() |> Enum.map(& &1.path)

    refute Enum.any?(paths, &String.contains?(&1, "/register"))
    refute Enum.any?(paths, &String.contains?(&1, "/profile"))
    refute Enum.any?(paths, &String.contains?(&1, "/users"))
    refute Enum.any?(paths, &String.contains?(&1, "/oauth"))
    refute Enum.any?(paths, &String.contains?(&1, "/social"))
  end
end
