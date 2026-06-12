defmodule HiraethWeb.AdminAuthLiveTest do
  use HiraethWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias Hiraeth.Accounts.User

  test "unauthenticated admin LiveView redirects to sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin")
  end

  test "authenticated seeded admin reaches admin dashboard and propagates actor into Ash actions",
       %{conn: conn} do
    signed_in =
      seed_admin!("live-admin@example.test", "correct horse battery staple")
      |> sign_in!("correct horse battery staple")

    conn =
      conn
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(signed_in)

    assert {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "Admin dashboard"
    assert html =~ "live-admin@example.test"
    refute html =~ "actor-probe"

    assert {:ok, _probe_view, probe_html} = live(conn, ~p"/admin/__actor_probe")
    assert probe_html =~ "actor propagated for actor-probe-"
  end

  defp seed_admin!(email, password) do
    User
    |> Ash.Changeset.for_create(:seed_admin, %{
      email: email,
      password: password,
      display_name: "Live Admin"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in!(user, password) do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: user.email, password: password})
    |> Ash.read_one!()
  end
end
