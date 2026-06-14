defmodule HiraethWeb.PublicCatalogLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Hiraeth.Catalog.Edition
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.RealCatalog.Dataset
  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

  @search_interaction_budget_microseconds 75_000

  @immigrant_slug "deep-vellum-immigrant-paperback-9781646054541"

  setup_all do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Hiraeth.Repo, fn ->
      Hiraeth.RealCatalogFixtures.seed!()
    end)

    :ok
  end

  test "home and browse render real publisher catalog with pagination and filtering", %{
    conn: conn
  } do
    {:ok, home, _html} = live(conn, ~p"/")

    assert has_element?(home, "#home-shell")
    assert has_element?(home, "#home-spotlight")
    assert has_element?(home, "#recent-acquisitions")
    refute render(home) =~ "Spotlight Volume"

    {:ok, browse, _html} = live(conn, ~p"/browse")

    assert has_element?(browse, "#browse-shell")
    assert has_element?(browse, "#catalog-index", "79 books")
    assert has_element?(browse, "#catalog-page-count", "Page 1 of 4")
    assert has_element?(browse, "#book-reader")
    refute render(browse) =~ "Volume Reader"

    {:ok, filtered, _html} = live(conn, ~p"/browse?q=Immigrant")
    assert has_element?(filtered, "#catalog-index h4", "Immigrant")
    assert has_element?(filtered, "#catalog-index", "trilingual collection")
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

    assert Enum.any?(formats, fn format ->
             Map.take(format, [
               :edition_slug,
               :format,
               :format_label,
               :identifiers,
               :published_on
             ]) == %{
               edition_slug: "deep-vellum-immigrant-paperback-9781646054541",
               format: "paperback",
               format_label: "Paperback",
               identifiers: ["9781646054541"],
               published_on: ~D[2027-02-16]
             }
           end)

    assert Enum.any?(formats, fn format ->
             Map.take(format, [
               :edition_slug,
               :format,
               :format_label,
               :identifiers,
               :published_on
             ]) == %{
               edition_slug: "deep-vellum-immigrant-ebook-9781646054558",
               format: "ebook",
               format_label: "Ebook",
               identifiers: ["9781646054558"],
               published_on: ~D[2027-02-16]
             }
           end)

    assert Enum.sort(identifiers) == ["9781646054541", "9781646054558"]

    assert [%{source_record_id: source_record_id, import_run_id: import_run_id} | _] =
             books |> hd() |> Map.fetch!(:sources)

    assert is_binary(source_record_id)
    assert is_binary(import_run_id)

    {:ok, filtered, _html} = live(conn, ~p"/browse?q=Immigrant")
    document = filtered |> render() |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("#catalog-index h4") |> LazyHTML.to_tree() |> length() == 1
    assert has_element?(filtered, "#catalog-index", "paperback")
    assert has_element?(filtered, "#catalog-index", "ebook")
    assert has_element?(filtered, "#catalog-index", "9781646054541")
    assert has_element?(filtered, "#catalog-index", "9781646054558")
    assert has_element?(filtered, "#catalog-index", "by Joaquín Zihuatanejo")
    assert has_element?(filtered, "#catalog-index", "translated by David Bowles")
  end

  test "search filters real catalog without crashing on malformed text", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    assert has_element?(view, "#search-shell")
    assert has_element?(view, "#search-results", "79 matches")

    view
    |> form("#catalog-search-form", search: %{query: "Bob and Hilbert"})
    |> render_change()

    assert has_element?(view, "#search-results", "Bob and Hilbert")
    assert has_element?(view, "#search-results", "Archipelago Books")

    view
    |> form("#catalog-search-form", search: %{query: "][\'<>☃"})
    |> render_change()

    assert has_element?(view, "#search-empty", "No catalog entries match")

    view
    |> form("#catalog-search-form", search: %{query: "%"})
    |> render_change()

    assert has_element?(view, "#search-empty", "No catalog entries match")

    view
    |> form("#catalog-search-form", search: %{query: "_"})
    |> render_change()

    assert has_element?(view, "#search-empty", "No catalog entries match")
  end

  test "search route accepts indexed catalog filter params from the URL", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, ~p"/search?q=9781646054541&format=paperback&sort=newest")

    assert has_element?(view, "#search-results", "1 matches")
    assert has_element?(view, "#search-results", "Immigrant")
    assert has_element?(view, "#search-results", "9781646054541")
    refute render(view) =~ "Nelly's Version"
  end

  test "search interaction stays within local render_change budget", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    {_warm_microseconds, _html} =
      :timer.tc(fn ->
        view
        |> form("#catalog-search-form", search: %{query: "Immigrant"})
        |> render_change()
      end)

    {elapsed_microseconds, html} =
      :timer.tc(fn ->
        view
        |> form("#catalog-search-form", search: %{query: "Bob and Hilbert"})
        |> render_change()
      end)

    assert elapsed_microseconds <= @search_interaction_budget_microseconds
    assert html =~ "Bob and Hilbert"
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

  test "contributor index/detail routes render author and translator discovery", %{conn: conn} do
    {:ok, contributors, _html} = live(conn, ~p"/contributors")

    assert has_element?(contributors, "#contributors-shell")
    assert has_element?(contributors, "#contributor-david-bowles", "David Bowles")
    assert has_element?(contributors, "#contributor-joaquin-zihuatanejo", "Joaquín Zihuatanejo")
    refute render(contributors) =~ "/authors"
    refute render(contributors) =~ "/translators"

    {:ok, translators, _html} = live(conn, ~p"/contributors?role=translator")
    assert has_element?(translators, "#contributors-shell", "Translators")
    assert has_element?(translators, "#contributor-david-bowles", "translator")
    refute has_element?(translators, "#contributor-joaquin-zihuatanejo")

    {:ok, contributor, _html} = live(conn, ~p"/contributors/david-bowles")
    assert has_element?(contributor, "#contributor-detail-shell")
    assert has_element?(contributor, "#contributor-title", "David Bowles")
    assert has_element?(contributor, "#contributor-roles", "translator")
    assert has_element?(contributor, "#contributor-books", "Immigrant")
  end

  test "edition route redirects to canonical book detail with provenance and formats", %{
    conn: conn
  } do
    cache_cover_for_edition_slug!(
      @immigrant_slug,
      "deep_vellum_official_store",
      "https://cdn.shopify.com/s/files/1/fixture-live-immigrant.jpg",
      "live-test-immigrant.jpg",
      "Cover via Deep Vellum official source"
    )

    assert {:error, {:live_redirect, %{to: "/books/deep-vellum-immigrant"}}} =
             live(conn, ~p"/editions/#{@immigrant_slug}")

    {:ok, view, html} = live(conn, ~p"/books/deep-vellum-immigrant")
    File.mkdir_p!(".omo/evidence")
    File.write!(".omo/evidence/task-11-book-live-dom.html", render(view))

    assert has_element?(view, "#book-detail-shell")
    assert has_element?(view, "#book-title", "Immigrant")
    assert has_element?(view, "#book-authors", "by Joaquín Zihuatanejo")
    assert has_element?(view, "#book-translators", "translated by David Bowles")
    assert has_element?(view, "#book-identifiers", "9781646054541")
    assert has_element?(view, "#edition-provenance", "deep_vellum_official_store")
    assert has_element?(view, "#edition-provenance", "publisher_dataset")

    assert has_element?(
             view,
             "#cover-attribution-deep-vellum-immigrant",
             "Cover via Deep Vellum official source"
           )

    assert has_element?(view, "#publication-date", "2027-02-16")
    assert has_element?(view, "#book-description", "trilingual collection")

    assert has_element?(
             view,
             ~s|#public-cover-deep-vellum-immigrant img[src="/covers/cache/live-test-immigrant.jpg"]|
           )

    assert has_element?(view, "#book-formats", "Paperback")
    assert has_element?(view, "#book-format-deep-vellum-immigrant-paperback-9781646054541")
    assert has_element?(view, "#book-format-deep-vellum-immigrant-ebook-9781646054558")

    refute html =~ "jacket copy"
    refute html =~ "price"
    refute html =~ "inventory"
  end

  test "book detail displays sourced prose, editorial praise, and publisher storefront CTA", %{
    conn: conn
  } do
    clear_catalog!()
    tmp = prose_dataset_dir!()
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, _summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)

    cache_cover_for_edition_slug!(
      "archipelago-books-bob-and-hilbert-hardcover-9781962770651",
      "archipelago_books_official_store",
      "https://archipelagobooks.org/fixture-live-bob-and-hilbert.jpg",
      "live-test-bob-and-hilbert.jpg",
      "Cover via Archipelago Books official source"
    )

    assert {:error, {:live_redirect, %{to: "/books/archipelago-books-bob-and-hilbert"}}} =
             live(conn, ~p"/editions/archipelago-books-bob-and-hilbert-hardcover-9781962770651")

    {:ok, view, _html} = live(conn, ~p"/books/archipelago-books-bob-and-hilbert")
    File.mkdir_p!(".omo/evidence")
    File.write!(".omo/evidence/task-11-book-live-dom.html", render(view))

    assert has_element?(view, "#book-description", "Sourced publisher synopsis")
    assert has_element?(view, "#book-editorial-praise", "Publisher official page")

    assert has_element?(
             view,
             ~s|a#book-storefront-cta[href="https://archipelagobooks.org/book/bob-and-hilbert/"]|,
             "Publisher page"
           )
  end

  test "book cover component prefers optimized card derivatives and keeps hero originals" do
    html =
      render_component(&CatalogComponents.book_cover/1,
        book: %{
          slug: "cached-cover-book",
          title: "Cached Cover Book",
          publisher: "Fixture Press",
          cover: %{
            source_url: "https://covers.example.test/cached-cover-book.jpg",
            public_url: "/covers/cache/cached-cover-book.jpg",
            thumbnail_url: "/covers/cache/cached-cover-book-thumb.jpg",
            provider: "fixture-covers",
            attribution_text: "Fixture cover provider"
          }
        }
      )

    card_img = html |> LazyHTML.from_fragment() |> LazyHTML.query("img")

    assert LazyHTML.attribute(card_img, "src") == ["/covers/cache/cached-cover-book-thumb.jpg"]
    assert LazyHTML.attribute(card_img, "loading") == ["lazy"]
    assert LazyHTML.attribute(card_img, "decoding") == ["async"]
    assert LazyHTML.attribute(card_img, "width") == ["400"]
    assert LazyHTML.attribute(card_img, "height") == ["600"]

    hero_html =
      render_component(&CatalogComponents.book_cover/1,
        variant: "hero",
        loading: "eager",
        fetchpriority: "high",
        book: %{
          slug: "cached-cover-book",
          title: "Cached Cover Book",
          publisher: "Fixture Press",
          cover: %{
            source_url: "https://covers.example.test/cached-cover-book.jpg",
            public_url: "/covers/cache/cached-cover-book.jpg",
            thumbnail_url: "/covers/cache/cached-cover-book-thumb.jpg",
            provider: "fixture-covers",
            attribution_text: "Fixture cover provider"
          }
        }
      )

    hero_img = hero_html |> LazyHTML.from_fragment() |> LazyHTML.query("img")

    assert LazyHTML.attribute(hero_img, "src") == ["/covers/cache/cached-cover-book.jpg"]
    assert LazyHTML.attribute(hero_img, "loading") == ["eager"]
    assert LazyHTML.attribute(hero_img, "fetchpriority") == ["high"]
  end

  defp cache_cover_for_edition_slug!(slug, provider, source_url, filename, attribution_text) do
    cached_path = Path.join("priv/static/covers/cache", filename)
    File.mkdir_p!(Path.dirname(cached_path))
    File.write!(cached_path, "live test cached cover bytes")
    on_exit(fn -> File.rm(cached_path) end)

    edition =
      Edition
      |> Ash.read!()
      |> Enum.find(&(&1.slug == slug))

    cover_asset =
      CoverAsset
      |> Ash.Changeset.for_create(:create, %{
        source_url: source_url,
        provider: provider,
        rights_basis: "local_cache_permitted",
        attribution_text: attribution_text,
        cache_policy: "cache_allowed",
        cached_file_path: cached_path,
        cached_at: DateTime.utc_now(:second),
        takedown_state: "visible"
      })
      |> Ash.create!(authorize?: false)

    CoverAssignment
    |> Ash.Changeset.for_create(:create, %{
      edition_id: edition.id,
      cover_asset_id: cover_asset.id,
      position: -1,
      visible?: true
    })
    |> Ash.create!(authorize?: false)
  end

  defp clear_catalog! do
    for resource <- [
          Hiraeth.Sources.SourceLedgerEntry,
          Hiraeth.Sources.SourceRecord,
          Hiraeth.Imports.ImportRun,
          Hiraeth.Covers.CoverAssignment,
          Hiraeth.Covers.CoverAsset,
          Hiraeth.Catalog.Identifier,
          Hiraeth.Catalog.Contribution,
          Hiraeth.Catalog.Edition,
          Hiraeth.Catalog.Work,
          Hiraeth.Catalog.Imprint,
          Hiraeth.Catalog.Publisher
        ] do
      Hiraeth.Repo.delete_all(resource)
    end
  end

  defp prose_dataset_dir! do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-live-prose-catalog-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.cp!(Path.join(Dataset.default_dir(), "README.md"), Path.join(tmp, "README.md"))
    File.cp!(Path.join(Dataset.default_dir(), "schema.json"), Path.join(tmp, "schema.json"))

    {:ok, dataset} = Dataset.load_file(Path.join(Dataset.default_dir(), "archipelago_books.json"))
    [record | remaining_records] = dataset.records

    prose_record =
      record
      |> Map.put(:description, "Sourced publisher synopsis for Bob and Hilbert.")
      |> Map.put(:storefront_url, record.source_uri)
      |> Map.put(:editorial_praise, [
        %{
          quote: "A precise, source-attributed editorial praise excerpt.",
          source: "Publisher official page",
          source_uri: record.source_uri
        }
      ])
      |> Map.update!(:displayed_fields, fn fields ->
        Enum.uniq(fields ++ ["description", "editorial_praise", "storefront_url"])
      end)
      |> Map.update!(:field_sources, fn sources ->
        field_source = %{
          provider: dataset.provider,
          source_uri: record.source_uri,
          source_type: "publisher_dataset",
          rights_basis: dataset.license_note
        }

        sources
        |> Map.put("description", field_source)
        |> Map.put("editorial_praise", field_source)
        |> Map.put("storefront_url", field_source)
      end)

    payload = %{
      provider: dataset.provider,
      retrieved_at: dataset.retrieved_at,
      license_note: dataset.license_note,
      provider_permissions: dataset.provider_permissions,
      records: [prose_record | remaining_records]
    }

    File.write!(Path.join(tmp, "archipelago_books.json"), Jason.encode!(payload, pretty: true))
    tmp
  end
end
