defmodule HiraethWeb.RouteShellLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Hiraeth.Accounts.User

  setup_all do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Hiraeth.Repo, fn ->
      Hiraeth.RealCatalogFixtures.seed!()
    end)

    :ok
  end

  test "GET / renders the editorial home shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-shell")
    assert has_element?(view, "#home-spotlight")
    assert has_element?(view, "#recent-acquisitions")
  end

  test "GET /browse filters real books and displays details on selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/browse")

    assert has_element?(view, "#browse-shell")
    assert has_element?(view, "#catalog-index", "79 books")
    assert has_element?(view, "#catalog-page-count", "Page 1 of 4")

    {:ok, filtered, _html} = live(conn, ~p"/browse?q=Tunnel")
    assert has_element?(filtered, "#catalog-index h4", "The Tunnel")
    assert has_element?(filtered, "#book-reader dd", "William H. Gass")
  end

  test "GET /search filters items dynamically", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    assert has_element?(view, "#search-shell")
    assert has_element?(view, "#search-results", "79 matches")

    view
    |> form("#catalog-search-form", search: %{query: "Archipelago"})
    |> render_change()

    assert has_element?(view, "#search-results td", "Archipelago Books")

    view
    |> form("#catalog-search-form", search: %{query: "][\'<>☃"})
    |> render_change()

    assert has_element?(view, "#search-empty", "No catalog entries match")
  end

  test "GET /publishers renders the real publisher directory", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/publishers")

    assert has_element?(view, "#publishers-shell")
    assert has_element?(view, "#publisher-deep-vellum")
    assert has_element?(view, "#publisher-dalkey-archive")
    assert has_element?(view, "#publisher-archipelago-books")
  end

  test "GET /series renders grouped collection shell even when pilot data has no series", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/series")
    assert has_element?(view, "#series-shell")
  end

  test "GET /admin renders the authenticated admin shell", %{conn: conn} do
    signed_in =
      seed_admin!("route-shell-admin@example.test", "correct horse battery staple")
      |> sign_in!("correct horse battery staple")

    conn =
      conn
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(signed_in)

    {:ok, view, html} = live(conn, ~p"/admin")

    assert html =~ "Admin dashboard"
    assert has_element?(view, "#admin-dashboard-shell")
    assert has_element?(view, "#admin-import-runs")
  end

  defp seed_admin!(email, password) do
    User
    |> Ash.Changeset.for_create(:seed_admin, %{
      email: email,
      password: password,
      display_name: "Route Shell Admin"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in!(user, password) do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: user.email, password: password})
    |> Ash.read_one!()
  end
end
