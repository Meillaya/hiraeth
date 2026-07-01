defmodule HiraethWeb.RouteShellLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias HiraethWeb.PublicCatalog

  setup_all do
    Hiraeth.CatalogCleanup.ensure_committed_catalog_fixtures!()
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

    assert has_element?(
             view,
             "#catalog-index",
             "#{PublicCatalog.book_page(nil, 1).total_count} books"
           )

    assert has_element?(
             view,
             "#catalog-page-count",
             "Page 1 of #{ceil_div(PublicCatalog.book_page(nil, 1).total_count, PublicCatalog.page_size())}"
           )

    {:ok, filtered, _html} = live(conn, ~p"/browse?q=Tunnel")
    assert has_element?(filtered, "#catalog-index h4", "The Tunnel")
    assert has_element?(filtered, "#book-reader dd", "William H. Gass")
  end

  test "GET /search filters items dynamically", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    assert has_element?(view, "#search-shell")

    assert has_element?(
             view,
             "#search-results",
             "#{PublicCatalog.book_page(nil, 1).total_count} matches"
           )

    view
    |> form("#catalog-search-form", search: %{query: "Archipelago"})
    |> render_change()

    assert has_element?(view, "#search-results", "Archipelago Books")

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

  test "Todo 7 route shells do not nest main landmarks inside the app layout", %{conn: conn} do
    assert_single_main(conn, ~p"/search", "#search-shell")
    assert_single_main(conn, ~p"/contributors", "#contributors-shell")
    assert_single_main(conn, ~p"/contributors/david-bowles", "#contributor-detail-shell")
    assert_single_main(conn, ~p"/series", "#series-shell")
    assert_single_main(conn, ~p"/books/deep-vellum-immigrant", "#book-detail-shell")
    assert_single_main(conn, ~p"/editions/not-a-real-edition", "#edition-detail-shell")
  end

  defp assert_single_main(conn, path, shell_selector) do
    {:ok, _view, html} = live(conn, path)
    document = LazyHTML.from_fragment(html)

    assert document |> LazyHTML.query(shell_selector) |> LazyHTML.to_tree() |> length() == 1
    assert document |> LazyHTML.query("main") |> LazyHTML.to_tree() |> length() == 1

    assert document |> LazyHTML.query("main #{shell_selector}") |> LazyHTML.to_tree() |> length() ==
             1
  end

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
end
