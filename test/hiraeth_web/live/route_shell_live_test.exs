defmodule HiraethWeb.RouteShellLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Hiraeth.Accounts.User

  setup do
    Hiraeth.DemoFixtures.seed!()
    :ok
  end

  test "GET / renders the editorial home shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-shell")
    assert has_element?(view, "#home-spotlight h2", "The Orchard of Minor Moons")
    assert has_element?(view, "#recent-acquisitions")
  end

  test "GET /browse filters books and displays details on selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/browse")

    assert has_element?(view, "#browse-shell")
    assert has_element?(view, "#volume-reader dd", "The Orchard of Minor Moons")
    assert has_element?(view, "#volume-reader dd", "Iris Vale")
    assert has_element?(view, "#catalog-index h4", "Index of Borrowed Harbors")
    refute has_element?(view, "#catalog-index h4", "Rooms for Unwritten Letters")

    assert has_element?(view, "#catalog-page-count", "Page 1 of 2")

    {:ok, page_two, _html} = live(conn, ~p"/browse?page=2")
    assert has_element?(page_two, "#catalog-index h4", "Rooms for Unwritten Letters")

    {:ok, filtered, _html} = live(conn, ~p"/browse?q=Harbors")
    refute has_element?(filtered, "#catalog-index h4", "The Orchard of Minor Moons")
    assert has_element?(filtered, "#catalog-index h4", "Index of Borrowed Harbors")
  end

  test "GET /search filters items dynamically", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    assert has_element?(view, "#search-shell")
    assert has_element?(view, "#search-results td", "The Orchard of Minor Moons")
    assert has_element?(view, "#search-results td", "Index of Borrowed Harbors")
    assert has_element?(view, "#search-results td", "Rooms for Unwritten Letters")

    view
    |> form("#catalog-search-form", search: %{query: "Harbors"})
    |> render_change()

    assert has_element?(view, "#search-results td", "Index of Borrowed Harbors")
    refute has_element?(view, "#search-results td", "The Orchard of Minor Moons")

    view
    |> form("#catalog-search-form", search: %{query: "]['<>☃"})
    |> render_change()

    assert has_element?(view, "#search-results", "No catalog entries match")
  end

  test "GET /publishers renders the curated imprints directory", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/publishers")

    assert has_element?(view, "#publishers-shell")
    assert has_element?(view, "#publisher-moth-house-editions")
    assert has_element?(view, "#publisher-lantern-current-books")
    assert has_element?(view, "#publisher-blue-thistle-archive")
    assert has_element?(view, "#publisher-blue-thistle-archive")
  end

  test "GET /series renders grouped collection shells", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/series")

    assert has_element?(view, "#series-shell")
    assert has_element?(view, "#series-pocket-weather-library")
    assert has_element?(view, "#series-harbor-essays")
    assert has_element?(view, "#series-recovered-rooms")
    assert has_element?(view, "#series-recovered-rooms")
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
