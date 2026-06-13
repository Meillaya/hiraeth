defmodule HiraethWeb.PublicCatalogPerformanceTest do
  use HiraethWeb.ConnCase, async: false

  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Work}
  alias Hiraeth.QueryCounting
  alias HiraethWeb.PublicCatalog

  @list_query_budget 8
  @detail_query_budget 8
  @directory_query_budget 8
  @warm_elapsed_budget_microseconds 50_000

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

  test "book page has bounded query count and elapsed time for the first browse page" do
    %{result: page} = warm_measure(fn -> PublicCatalog.book_page(nil, 1) end)
    measurement = warm_measure(fn -> PublicCatalog.book_page(nil, 1) end)

    assert page.total_count == 79
    assert length(page.entries) == PublicCatalog.page_size()
    assert measurement.query_count <= @list_query_budget
    assert measurement.elapsed_microseconds <= @warm_elapsed_budget_microseconds
  end

  test "filtered book page has bounded query count for text, ISBN, malformed, and Unicode searches" do
    for query <- ["Immigrant", "9781646054541", "][\'<>☃", "%", "_", "月"] do
      measurement = warm_measure(fn -> PublicCatalog.book_page(query, 1) end)

      assert measurement.query_count <= @list_query_budget
      assert measurement.elapsed_microseconds <= @warm_elapsed_budget_microseconds
      assert Enum.uniq_by(measurement.result.entries, & &1.work_id) == measurement.result.entries
    end
  end

  test "book detail lookup has bounded query count and does not require all catalog scans" do
    measurement = warm_measure(fn -> PublicCatalog.book("deep-vellum-immigrant") end)

    assert %{title: "Immigrant", formats: formats} = measurement.result
    assert length(formats) == 2
    assert measurement.query_count <= @detail_query_budget
    assert measurement.elapsed_microseconds <= @warm_elapsed_budget_microseconds
  end

  test "publisher and series directories have bounded query count" do
    publisher_index = warm_measure(fn -> PublicCatalog.publishers() end)
    publisher_detail = warm_measure(fn -> PublicCatalog.publisher("deep-vellum") end)
    series_index = warm_measure(fn -> PublicCatalog.series() end)

    series_detail =
      warm_measure(fn -> PublicCatalog.series_by_slug("spanish-literature-series") end)

    assert length(publisher_index.result) == 3
    assert %{slug: "deep-vellum"} = publisher_detail.result
    assert is_list(series_index.result)

    for measurement <- [publisher_index, publisher_detail, series_index, series_detail] do
      assert measurement.query_count <= @directory_query_budget
      assert measurement.elapsed_microseconds <= @warm_elapsed_budget_microseconds
    end
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

  defp warm_measure(fun) do
    _warm = QueryCounting.measure(fun)
    QueryCounting.measure(fun)
  end
end
