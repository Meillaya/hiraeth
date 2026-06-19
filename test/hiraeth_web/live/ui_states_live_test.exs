defmodule HiraethWeb.UiStatesLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Series, SeriesMembership, Work}
  alias Hiraeth.Sources.SourceRecord
  alias HiraethWeb.CatalogComponents

  test "reusable state components render loading and generic errors" do
    assert render_component(&CatalogComponents.loading_skeleton/1,
             id: "state-loading",
             label: "Loading catalog cards"
           ) =~ "Loading catalog cards"

    assert render_component(&CatalogComponents.error_block/1,
             id: "state-error",
             title: "Could not read shelf",
             message: "The archive kept your filters intact."
           ) =~ "The archive kept your filters intact."
  end

  test "empty catalog and query states preserve the user's filter context", %{conn: conn} do
    {:ok, browse, _html} = live(conn, ~p"/browse?q=zzzz-no-catalog-match-🚫&page=99")
    assert has_element?(browse, "#browse-empty", "No catalog entries match")
    assert has_element?(browse, "#browse-empty", "zzzz-no-catalog-match-🚫")
    assert has_element?(browse, "#book-reader-empty", "Adjust or clear the current search")
  end

  test "not-found and missing-cover states are explicit", %{conn: conn} do
    Hiraeth.DemoFixtures.seed!()

    {:ok, publisher, _html} = live(conn, ~p"/publishers/not-a-publisher")
    assert has_element?(publisher, "#publisher-not-found", "No publisher matches")
    assert has_element?(publisher, "a[href='/publishers']", "Back to publishers")

    assert {:error, {:live_redirect, %{to: "/books/the-orchard-of-minor-moons-paperback"}}} =
             live(conn, ~p"/editions/the-orchard-of-minor-moons-paperback")

    {:ok, book, _html} = live(conn, ~p"/books/the-orchard-of-minor-moons-paperback")
    assert has_element?(book, "#missing-cover-note", "No sourced cover asset")
    assert has_element?(book, "#missing-cover-the-orchard-of-minor-moons-paperback")

    {:ok, missing, _html} = live(conn, ~p"/editions/not-an-edition")
    assert has_element?(missing, "#edition-not-found", "No edition matches")
    assert has_element?(missing, "a[href='/browse']", "Back to browse")
  end

  test "publisher with no editions and series with unknown order explain their state", %{
    conn: conn
  } do
    admin = %{id: Ash.UUID.generate(), catalog_write?: true}

    publisher =
      create!(Publisher, %{name: "Empty Shelf Press", slug: "empty-shelf-press"}, admin)

    {:ok, publisher_view, _html} = live(conn, ~p"/publishers/#{publisher.slug}")
    assert has_element?(publisher_view, "#publisher-no-editions", "No books are attached")

    series = create!(Series, %{title: "Unnumbered Sequence", slug: "unnumbered-sequence"}, admin)
    work = create!(Work, %{title: "Loose Leaf Noon", slug: "loose-leaf-noon"}, admin)

    edition =
      create!(
        Edition,
        %{
          title: "Loose Leaf Noon",
          slug: "loose-leaf-noon-paperback",
          format: "paperback",
          work_id: work.id,
          publisher_id: publisher.id
        },
        admin
      )

    create!(SeriesMembership, %{series_id: series.id, work_id: work.id, position: nil}, admin)

    create!(
      Identifier,
      %{identifier_type: "isbn_13", value: "9780000001998", edition_id: edition.id},
      admin
    )

    create!(
      SourceRecord,
      %{
        provider: "local_demo_fixture",
        source_type: "fixture",
        source_uri: "local_demo_fixture:edition:#{edition.slug}",
        license_note: "Local test fixture.",
        source_identity: "9780000001998",
        edition_id: edition.id,
        raw_payload: %{"edition" => %{"isbn_13" => "9780000001998", "title" => "Loose Leaf Noon"}},
        imported_at: DateTime.utc_now(:second)
      },
      admin
    )

    {:ok, series_view, _html} = live(conn, ~p"/series/#{series.slug}")
    assert has_element?(series_view, "#series-unknown-order", "Sequence order is not sourced")
    assert has_element?(series_view, "#series-editions", "Loose Leaf Noon")
  end

  defp create!(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: actor)
  end
end
