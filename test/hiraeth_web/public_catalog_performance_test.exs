defmodule HiraethWeb.PublicCatalogPerformanceTest do
  use HiraethWeb.ConnCase, async: false

  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Work}
  alias HiraethWeb.PublicCatalog

  setup do
    Hiraeth.RealCatalogFixtures.seed!()
    :ok
  end

  test "paged public catalog excludes records without source provenance" do
    create_source_less_edition!()

    page = PublicCatalog.book_page("Source Less Invisible", 1)

    assert page.total_count == 0
    assert page.entries == []
  end

  test "grouped public catalog search is fast and returns no duplicate book cards" do
    assert function_exported?(PublicCatalog, :search_books, 1),
           "PublicCatalog.search_books/1 must exist before public catalog performance can be measured"

    {elapsed_microseconds, books} = :timer.tc(fn -> apply(PublicCatalog, :search_books, [""]) end)

    assert elapsed_microseconds <= 100_000
    assert length(books) > 0
    assert length(books) <= PublicCatalog.page_size()

    book_keys = Enum.map(books, & &1.work_id)
    assert Enum.uniq(book_keys) == book_keys
  end

  defp create_source_less_edition! do
    suffix = System.unique_integer([:positive])

    publisher =
      Publisher
      |> Ash.Changeset.for_create(:create, %{
        name: "Source Less Test Press #{suffix}",
        slug: "source-less-test-press-#{suffix}"
      })
      |> Ash.create!(authorize?: false)

    work =
      Work
      |> Ash.Changeset.for_create(:create, %{
        title: "Source Less Invisible",
        slug: "source-less-invisible-#{suffix}",
        publication_state: "published"
      })
      |> Ash.create!(authorize?: false)

    edition =
      Edition
      |> Ash.Changeset.for_create(:create, %{
        title: "Source Less Invisible",
        slug: "source-less-invisible-paperback-#{suffix}",
        format: "paperback",
        work_id: work.id,
        publisher_id: publisher.id
      })
      |> Ash.create!(authorize?: false)

    Identifier
    |> Ash.Changeset.for_create(:create, %{
      identifier_type: "isbn_13",
      value: "979000000#{String.pad_leading(to_string(rem(suffix, 10_000)), 4, "0")}",
      edition_id: edition.id
    })
    |> Ash.create!(authorize?: false)
  end
end
