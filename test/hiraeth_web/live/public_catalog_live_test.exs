defmodule HiraethWeb.PublicCatalogLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HiraethWeb.PublicCatalog

  @immigrant_slug "deep-vellum-immigrant-paperback-9781646054541"

  setup do
    Hiraeth.RealCatalogFixtures.seed!()
    :ok
  end

  test "home and browse render real publisher catalog with pagination and filtering", %{
    conn: conn
  } do
    {:ok, home, _html} = live(conn, ~p"/")

    assert has_element?(home, "#home-shell")
    assert has_element?(home, "#home-spotlight")
    assert has_element?(home, "#recent-acquisitions")

    {:ok, browse, _html} = live(conn, ~p"/browse")

    assert has_element?(browse, "#browse-shell")
    assert has_element?(browse, "#catalog-index", "150 volumes")
    assert has_element?(browse, "#catalog-page-count", "Page 1 of 75")

    {:ok, filtered, _html} = live(conn, ~p"/browse?q=Immigrant")
    assert has_element?(filtered, "#catalog-index h4", "Immigrant")
    refute has_element?(filtered, "#catalog-empty")

    {:ok, no_results, _html} = live(conn, ~p"/browse?q=not-a-seeded-title")
    assert has_element?(no_results, "#catalog-empty", "No catalog entries match")
  end

  test "public catalog groups multiple formats under one logical book entry", %{conn: conn} do
    assert function_exported?(PublicCatalog, :search_books, 1),
           "PublicCatalog.search_books/1 must return work-centric public book projections"

    books = apply(PublicCatalog, :search_books, ["Immigrant"])

    assert [%{title: "Immigrant", formats: formats, identifiers: identifiers}] = books
    assert length(formats) == 2
    assert Enum.map(formats, & &1.format) |> Enum.sort() == ["ebook", "paperback"]

    assert %{
             edition_slug: "deep-vellum-immigrant-paperback-9781646054541",
             format: "paperback",
             format_label: "Paperback",
             identifiers: ["9781646054541"],
             published_on: ~D[2027-02-16]
           } in formats

    assert %{
             edition_slug: "deep-vellum-immigrant-ebook-9781646054558",
             format: "ebook",
             format_label: "Ebook",
             identifiers: ["9781646054558"],
             published_on: ~D[2027-02-16]
           } in formats

    assert Enum.sort(identifiers) == ["9781646054541", "9781646054558"]

    {:ok, filtered, _html} = live(conn, ~p"/browse?q=Immigrant")
    document = filtered |> render() |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("#catalog-index h4") |> LazyHTML.to_tree() |> length() == 1
    assert has_element?(filtered, "#catalog-index", "paperback")
    assert has_element?(filtered, "#catalog-index", "ebook")
    assert has_element?(filtered, "#catalog-index", "9781646054541")
    assert has_element?(filtered, "#catalog-index", "9781646054558")
  end

  test "search filters real catalog without crashing on malformed text", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    assert has_element?(view, "#search-shell")
    assert has_element?(view, "#search-results", "150 matches")

    view
    |> form("#catalog-search-form", search: %{query: "Bob and Hilbert"})
    |> render_change()

    assert has_element?(view, "#search-results", "Bob and Hilbert")
    assert has_element?(view, "#search-results", "Archipelago Books")

    view
    |> form("#catalog-search-form", search: %{query: "][\'<>☃"})
    |> render_change()

    assert has_element?(view, "#search-empty", "No catalog entries match")
  end

  test "publisher index/detail routes render real publishers", %{conn: conn} do
    {:ok, publishers, _html} = live(conn, ~p"/publishers")

    assert has_element?(publishers, "#publishers-shell")
    assert has_element?(publishers, "#publisher-deep-vellum")
    assert has_element?(publishers, "#publisher-dalkey-archive")
    assert has_element?(publishers, "#publisher-archipelago-books")

    {:ok, publisher, _html} = live(conn, ~p"/publishers/deep-vellum")
    assert has_element?(publisher, "#publisher-detail-shell")
    assert has_element?(publisher, "#publisher-title", "Deep Vellum")
    assert has_element?(publisher, "#publisher-editions", "Immigrant")
  end

  test "edition detail shows real provenance, factual fields, and no jacket copy", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/editions/#{@immigrant_slug}")

    assert has_element?(view, "#edition-detail-shell")
    assert has_element?(view, "#edition-title", "Immigrant")
    assert has_element?(view, "#edition-contributors", "Joaquín Zihuatanejo")
    assert has_element?(view, "#edition-contributors", "David Bowles")
    assert has_element?(view, "#edition-identifiers", "9781646054541")
    assert has_element?(view, "#edition-provenance", "deep_vellum_official_store")
    assert has_element?(view, "#edition-provenance", "publisher_dataset")

    assert has_element?(
             view,
             "#cover-attribution-deep-vellum-immigrant-paperback-9781646054541",
             "Cover via Deep Vellum official source"
           )

    assert has_element?(view, "#publication-date", "2027-02-16")

    refute html =~ "Description"
    refute html =~ "jacket copy"
    refute html =~ "price"
    refute html =~ "inventory"
  end
end
