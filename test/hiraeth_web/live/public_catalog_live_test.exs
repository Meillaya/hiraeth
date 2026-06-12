defmodule HiraethWeb.PublicCatalogLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Hiraeth.DemoFixtures.seed!()
    :ok
  end

  test "home and browse render Ash-backed seeded fixtures with pagination and fallbacks", %{
    conn: conn
  } do
    {:ok, home, _html} = live(conn, ~p"/")

    assert has_element?(home, "#home-shell")
    assert has_element?(home, "#home-spotlight h2", "The Orchard of Minor Moons")
    assert has_element?(home, "#recent-acquisitions", "Index of Borrowed Harbors")

    {:ok, browse, _html} = live(conn, ~p"/browse")

    assert has_element?(browse, "#browse-shell")
    assert has_element?(browse, "#catalog-index h4", "The Orchard of Minor Moons")
    assert has_element?(browse, "#catalog-index h4", "Index of Borrowed Harbors")
    refute has_element?(browse, "#catalog-index h4", "Rooms for Unwritten Letters")
    assert has_element?(browse, "#catalog-page-count", "Page 1 of 2")
    assert has_element?(browse, "#missing-cover-the-orchard-of-minor-moons-paperback")

    {:ok, second_page, _html} = live(conn, ~p"/browse?page=2")
    assert has_element?(second_page, "#catalog-index h4", "Rooms for Unwritten Letters")
    assert has_element?(second_page, "#catalog-page-count", "Page 2 of 2")

    {:ok, filtered, _html} = live(conn, ~p"/browse?q=Harbors")
    assert has_element?(filtered, "#catalog-index h4", "Index of Borrowed Harbors")
    refute has_element?(filtered, "#catalog-index h4", "The Orchard of Minor Moons")

    {:ok, no_results, _html} = live(conn, ~p"/browse?q=not-a-seeded-title")
    assert has_element?(no_results, "#catalog-empty", "No catalog entries match")
  end

  test "search filters seeded catalog without crashing on malformed text", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    assert has_element?(view, "#search-shell")
    assert has_element?(view, "#search-results", "The Orchard of Minor Moons")
    assert has_element?(view, "#search-results", "Index of Borrowed Harbors")
    assert has_element?(view, "#search-results", "Rooms for Unwritten Letters")

    view
    |> form("#catalog-search-form", search: %{query: "Rain"})
    |> render_change()

    assert has_element?(view, "#search-empty", "No catalog entries match")

    view
    |> form("#catalog-search-form", search: %{query: "][\'<>☃"})
    |> render_change()

    assert has_element?(view, "#search-empty", "No catalog entries match")
  end

  test "publisher and series index/detail routes render seeded catalog", %{conn: conn} do
    {:ok, publishers, _html} = live(conn, ~p"/publishers")

    assert has_element?(publishers, "#publishers-shell")
    assert has_element?(publishers, "#publisher-moth-house-editions")
    assert has_element?(publishers, "#publisher-lantern-current-books")
    assert has_element?(publishers, "#publisher-blue-thistle-archive")

    {:ok, publisher, _html} = live(conn, ~p"/publishers/moth-house-editions")
    assert has_element?(publisher, "#publisher-detail-shell")
    assert has_element?(publisher, "#publisher-title", "Moth House Editions")
    assert has_element?(publisher, "#publisher-editions", "The Orchard of Minor Moons")

    {:ok, series, _html} = live(conn, ~p"/series")
    assert has_element?(series, "#series-shell")
    assert has_element?(series, "#series-pocket-weather-library")
    assert has_element?(series, "#series-harbor-essays")
    assert has_element?(series, "#series-recovered-rooms")

    {:ok, series_detail, _html} = live(conn, ~p"/series/pocket-weather-library")
    assert has_element?(series_detail, "#series-detail-shell")
    assert has_element?(series_detail, "#series-title", "Pocket Weather Library")
    assert has_element?(series_detail, "#series-editions", "The Orchard of Minor Moons")
  end

  test "edition detail shows provenance and known fields without fabricated unknowns", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/editions/the-orchard-of-minor-moons-paperback")

    assert has_element?(view, "#edition-detail-shell")
    assert has_element?(view, "#edition-title", "The Orchard of Minor Moons")
    assert has_element?(view, "#edition-contributors", "Iris Vale")
    assert has_element?(view, "#edition-identifiers", "9780000001011")
    assert has_element?(view, "#edition-provenance", "local_demo_fixture")

    assert has_element?(
             view,
             "#edition-provenance",
             "local_demo_fixture:edition:the-orchard-of-minor-moons-paperback"
           )

    assert has_element?(view, "#edition-provenance", "Imported:")
    assert has_element?(view, "#missing-cover-the-orchard-of-minor-moons-paperback")
    assert has_element?(view, "#publication-date", "Publication date unknown")

    refute html =~ "English"
    refute html =~ "208 pages"
    refute html =~ "Translated by"
  end
end
