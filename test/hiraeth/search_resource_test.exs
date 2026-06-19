defmodule Hiraeth.SearchResourceTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Catalog.{
    Contribution,
    Contributor,
    Edition,
    Identifier,
    Imprint,
    Publisher,
    Series,
    SeriesMembership,
    Work
  }

  alias Hiraeth.Search.Result, as: SearchResult

  setup do
    clear_catalog!()

    %{admin: trusted_catalog_actor()}
  end

  test "searches title, subtitle, contributor, publisher, series, and ISBN fields", %{
    admin: admin
  } do
    edition =
      fixture_catalog(admin,
        title: "A Garden of Forking Paths",
        subtitle: "Labyrinth Dispatches Zqx",
        publisher: "Silver Current Press",
        imprint: "Atrium Editions",
        contributor: "Mina Cartographer",
        series: "Labyrinth Library",
        isbn: "978-1-1111-1111-1"
      )

    assert [result] = search_results("forking")
    assert result.edition_id == edition.id
    assert result.title == "A Garden of Forking Paths"

    assert [result] = search_results("dispatches zqx")
    assert result.edition_id == edition.id

    assert [result] = search_results("cartographer")
    assert result.contributor_names == ["Mina Cartographer"]

    assert [result] = search_results("silver current")
    assert result.publisher_name == "Silver Current Press"

    assert [result] = search_results("labyrinth library")
    assert result.series_titles == ["Labyrinth Library"]

    assert [result] = search_results("9781111111111")
    assert result.identifiers == ["978-1-1111-1111-1"]
  end

  test "empty query returns a deterministic catalog page and no-match query returns no results",
       %{
         admin: admin
       } do
    fixture_catalog(admin, title: "000 Zed Archive", isbn: "978-2-2222-2222-2")
    fixture_catalog(admin, title: "000 Alpha Archive", isbn: "978-3-3333-3333-3")

    empty_titles =
      ""
      |> search_page(limit: 1_000)
      |> Map.fetch!(:results)
      |> Enum.map(& &1.title)

    assert "000 Alpha Archive" in empty_titles
    assert "000 Zed Archive" in empty_titles

    assert Enum.find_index(empty_titles, &(&1 == "000 Alpha Archive")) <
             Enum.find_index(empty_titles, &(&1 == "000 Zed Archive"))

    assert [] = search_results("not-present-anywhere")
  end

  test "offset pagination returns count, boundaries, and stable title ordering", %{admin: admin} do
    fixture_catalog(admin, title: "Pagination C", isbn: "978-4-0000-0000-3")
    fixture_catalog(admin, title: "Pagination A", isbn: "978-4-0000-0000-1")
    fixture_catalog(admin, title: "Pagination B", isbn: "978-4-0000-0000-2")

    first_page = search_page("pagination", limit: 2, offset: 0)
    second_page = search_page("pagination", limit: 2, offset: 2)
    empty_page = search_page("pagination", limit: 2, offset: 10)

    assert %Ash.Page.Offset{count: 3, limit: 2, offset: 0, more?: true} = first_page
    assert Enum.map(first_page.results, & &1.title) == ["Pagination A", "Pagination B"]

    assert %Ash.Page.Offset{count: 3, limit: 2, offset: 2, more?: false} = second_page
    assert Enum.map(second_page.results, & &1.title) == ["Pagination C"]

    assert %Ash.Page.Offset{count: 3, results: [], more?: false} = empty_page
  end

  test "search is exposed as an Ash read action on the search domain" do
    action_names =
      SearchResult
      |> Ash.Resource.Info.actions()
      |> Enum.map(& &1.name)

    assert :search in action_names
    assert %Ash.Page.Offset{} = search_page("", limit: 5)
  end

  defp search_results(query) do
    query
    |> search_page(limit: 10)
    |> Map.fetch!(:results)
  end

  defp search_page(query, opts) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    SearchResult
    |> Ash.Query.for_read(:search, %{query: query})
    |> Ash.read!(authorize?: true, page: [limit: limit, offset: offset, count: true])
  end

  defp fixture_catalog(admin, attrs) do
    suffix = System.unique_integer([:positive])
    title = Keyword.fetch!(attrs, :title)
    isbn = Keyword.fetch!(attrs, :isbn)

    publisher =
      create!(
        Publisher,
        %{
          name: Keyword.get(attrs, :publisher, "Search Press #{suffix}"),
          slug: unique_slug("publisher")
        },
        admin
      )

    imprint =
      create!(
        Imprint,
        %{
          name: Keyword.get(attrs, :imprint, "Search Imprint #{suffix}"),
          slug: unique_slug("imprint"),
          publisher_id: publisher.id
        },
        admin
      )

    work =
      create!(
        Work,
        %{
          title: title,
          subtitle: Keyword.get(attrs, :subtitle),
          slug: unique_slug("work"),
          publication_state: "published"
        },
        admin
      )

    edition =
      create!(
        Edition,
        %{
          title: title,
          subtitle: Keyword.get(attrs, :subtitle),
          slug: unique_slug("edition"),
          work_id: work.id,
          publisher_id: publisher.id,
          imprint_id: imprint.id,
          format: "paperback"
        },
        admin
      )

    contributor =
      create!(
        Contributor,
        %{
          display_name: Keyword.get(attrs, :contributor, "Search Contributor #{suffix}"),
          sort_name: "Contributor, Search #{suffix}",
          slug: unique_slug("contributor")
        },
        admin
      )

    create!(
      Contribution,
      %{contributor_id: contributor.id, edition_id: edition.id, role: "author", position: 1},
      admin
    )

    series =
      create!(
        Series,
        %{
          title: Keyword.get(attrs, :series, "Search Series #{suffix}"),
          slug: unique_slug("series"),
          publisher_id: publisher.id
        },
        admin
      )

    create!(SeriesMembership, %{series_id: series.id, work_id: work.id, position: 1}, admin)
    create!(Identifier, %{identifier_type: "isbn_13", value: isbn, edition_id: edition.id}, admin)

    edition
  end

  defp create!(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: actor)
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp clear_catalog! do
    [
      Hiraeth.Sources.SourceLedgerEntry,
      Hiraeth.Sources.SourceRecord,
      Hiraeth.Covers.CoverAssignment,
      Hiraeth.Covers.CoverAsset,
      Identifier,
      Contribution,
      Edition,
      SeriesMembership,
      Series,
      Work,
      Imprint,
      Publisher
    ]
    |> Enum.each(fn resource ->
      Hiraeth.Repo.delete_all(resource)
    end)
  end
end
