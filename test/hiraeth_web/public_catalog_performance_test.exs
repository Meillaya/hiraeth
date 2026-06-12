defmodule HiraethWeb.PublicCatalogPerformanceTest do
  use HiraethWeb.ConnCase, async: false

  alias HiraethWeb.PublicCatalog

  setup do
    Hiraeth.RealCatalogFixtures.seed!()
    :ok
  end

  test "grouped public catalog search is fast and returns no duplicate book cards" do
    assert function_exported?(PublicCatalog, :search_books, 1),
           "PublicCatalog.search_books/1 must exist before public catalog performance can be measured"

    {elapsed_microseconds, books} = :timer.tc(fn -> apply(PublicCatalog, :search_books, [""]) end)

    assert elapsed_microseconds <= 100_000
    assert length(books) > 0

    book_keys = Enum.map(books, & &1.work_id)
    assert Enum.uniq(book_keys) == book_keys
  end
end
