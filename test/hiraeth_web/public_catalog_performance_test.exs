defmodule HiraethWeb.PublicCatalogPerformanceTest do
  use HiraethWeb.ConnCase, async: false

  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Series, SeriesMembership, Work}
  alias Hiraeth.QueryCounting
  alias HiraethWeb.PublicCatalog

  @list_query_budget 8
  @detail_query_budget 8
  @directory_query_budget 8
  @warm_elapsed_budget_microseconds 50_000

  setup_all do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Hiraeth.Repo, fn ->
      Hiraeth.RealCatalogFixtures.seed!()
    end)

    :ok
  end

  setup do
    create_series_membership!()
    :ok
  end

  test "paged public catalog excludes records without source provenance" do
    create_source_less_edition!()

    page = PublicCatalog.book_page("Source Less Invisible", 1)

    assert page.total_count == 0
    assert page.entries == []
  end

  test "publisher and series directories exclude records without source provenance" do
    %{publisher_slug: publisher_slug, series_slug: series_slug} = create_source_less_edition!()

    refute Enum.any?(PublicCatalog.publishers(), &(&1.slug == publisher_slug))
    assert PublicCatalog.publisher(publisher_slug) == nil

    refute Enum.any?(PublicCatalog.series(), &(&1.slug == series_slug))
    assert PublicCatalog.series_by_slug(series_slug) == nil
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

  test "facet filters and sorts are specified on the Postgres public read path" do
    filters = create_filter_contract_edition!()

    measurement = warm_measure(fn -> PublicCatalog.book_page(filters, 1) end)

    assert measurement.query_count <= @list_query_budget

    assert [%{title: "Facet Contract Novel", translators: translators} = book] =
             measurement.result.entries

    assert measurement.result.total_count == 1
    assert Enum.map(translators, & &1.slug) == [filters.contributor]
    assert hd(book.formats).format == "paperback"

    for sort <- ~w(newest title author recently_added) do
      page = PublicCatalog.book_page(%{filters | sort: sort}, 1)

      assert page.total_count == 1
      assert [%{title: "Facet Contract Novel"}] = page.entries
    end
  end

  test "facet filters keep malformed wildcard input literal and bounded" do
    for filters <- [
          %{q: "%", format: "ebook", sort: "title"},
          %{q: "_", publisher: "%", contributor: "_", sort: "newest"},
          %{q: "][\'<>☃", language: "eng", subject: "%", year: "not-a-year"}
        ] do
      measurement = warm_measure(fn -> PublicCatalog.book_page(filters, 1) end)

      assert measurement.query_count <= @list_query_budget
      assert measurement.elapsed_microseconds <= @warm_elapsed_budget_microseconds
      assert Enum.uniq_by(measurement.result.entries, & &1.work_id) == measurement.result.entries
    end
  end

  test "legacy Ash search result is marked internal so public UI cannot drift to in-memory filtering" do
    assert Hiraeth.Search.Result.public_catalog_path?() == false

    public_files = [
      "lib/hiraeth_web/live/browse_live.ex",
      "lib/hiraeth_web/live/search_live.ex",
      "lib/hiraeth_web/live/home_live.ex",
      "lib/hiraeth_web/live/book_live.ex",
      "lib/hiraeth_web/live/publishers_live.ex",
      "lib/hiraeth_web/live/series_live.ex"
    ]

    for file <- public_files do
      refute File.read!(file) =~ "Hiraeth.Search.Result",
             "#{file} must use HiraethWeb.PublicCatalog instead of in-memory Ash search"
    end
  end

  test "book detail lookup has bounded query count and does not require all catalog scans" do
    measurement = warm_measure(fn -> PublicCatalog.book("deep-vellum-immigrant") end)

    assert %{title: "Immigrant", formats: formats} = measurement.result
    assert length(formats) == 2
    assert measurement.query_count <= @detail_query_budget
    assert measurement.elapsed_microseconds <= @warm_elapsed_budget_microseconds
  end

  test "book projection exposes contributor roles without dropping generic contributors" do
    book = PublicCatalog.book("deep-vellum-immigrant")

    assert %{contributors_by_role: contributors_by_role} = book
    assert Map.keys(contributors_by_role) |> Enum.sort() == ["author", "translator"]
    assert Enum.map(book.authors, & &1.name) == ["Joaquín Zihuatanejo"]
    assert Enum.map(book.translators, & &1.name) == ["David Bowles"]
    assert book.author == "Joaquín Zihuatanejo, David Bowles"
    assert book.contributor_names == ["Joaquín Zihuatanejo", "David Bowles"]
    assert get_in(contributors_by_role, ["author", Access.at(0), :role]) == "author"
    assert get_in(contributors_by_role, ["translator", Access.at(0), :role]) == "translator"

    assert PublicCatalog.search_editions("Joaquín Zihuatanejo")
           |> Enum.any?(&(&1.title == "Immigrant"))
  end

  test "book projection exposes enriched metadata from bounded sourced rows" do
    slug = create_enriched_projection_edition!()

    measurement = warm_measure(fn -> PublicCatalog.book(slug) end)
    book = measurement.result

    assert book.title == "Projection Contract Novel"
    assert book.original_title == "Roman de projection"
    assert book.original_language_code == "fra"
    assert book.subjects == ["projection-subject", "metadata-contract"]
    assert book.source.provider == "deep_vellum_official_store"
    assert book.source.field_sources["page_count"]["provider"] == "deep_vellum_official_store"

    assert [%{language_code: "eng", page_count: 321, dimensions: dimensions}] = book.formats
    assert dimensions == %{height_mm: 203, width_mm: 127, depth_mm: 24}
    assert measurement.query_count <= @detail_query_budget
    assert measurement.elapsed_microseconds <= @warm_elapsed_budget_microseconds
  end

  test "publisher and series directories have bounded query count" do
    publisher_index = warm_measure(fn -> PublicCatalog.publishers() end)
    publisher_detail = warm_measure(fn -> PublicCatalog.publisher("deep-vellum") end)
    series_index = warm_measure(fn -> PublicCatalog.series() end)
    series_slug = series_index.result |> List.first() |> Map.fetch!(:slug)

    series_detail = warm_measure(fn -> PublicCatalog.series_by_slug(series_slug) end)

    assert Enum.any?(publisher_index.result, &(&1.slug == "deep-vellum"))
    assert %{slug: "deep-vellum"} = publisher_detail.result
    assert is_list(series_index.result)
    refute broad_edition_projection_query?(publisher_index)
    refute broad_edition_projection_query?(series_index)
    assert scoped_edition_projection_query?(publisher_detail, "where e.publisher_id = $1::uuid")

    assert scoped_edition_projection_query?(
             series_detail,
             "where e.work_id = any($1::uuid[])"
           )

    for measurement <- [publisher_index, publisher_detail, series_index, series_detail] do
      assert measurement.query_count <= @directory_query_budget
      assert measurement.elapsed_microseconds <= @warm_elapsed_budget_microseconds
    end
  end

  test "public catalog ids are UTF-8 UUID strings safe for LiveView stream DOM ids" do
    page = PublicCatalog.book_page(nil, 1)
    publisher = PublicCatalog.publisher("deep-vellum")
    series_slug = PublicCatalog.series() |> List.first() |> Map.fetch!(:slug)
    series = PublicCatalog.series_by_slug(series_slug)

    ids =
      [
        Enum.flat_map(page.entries, &[&1.id, &1.work_id]),
        [publisher.id],
        Enum.flat_map(publisher.editions, &[&1.id, &1.work_id]),
        [series.id],
        Enum.flat_map(series.editions, &[&1.id, &1.work_id])
      ]
      |> List.flatten()

    assert ids != []

    for id <- ids do
      assert is_binary(id)
      assert String.valid?(id), "expected #{inspect(id)} to be valid UTF-8"
      assert {:ok, _uuid} = Ecto.UUID.cast(id)
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

    series =
      Series
      |> Ash.Changeset.for_create(:create, %{
        title: "Source Less Test Series #{suffix}",
        slug: "source-less-test-series-#{suffix}",
        publisher_id: publisher.id
      })
      |> Ash.create!(authorize?: false)

    SeriesMembership
    |> Ash.Changeset.for_create(:create, %{
      series_id: series.id,
      work_id: work.id,
      position: 1,
      label: "1"
    })
    |> Ash.create!(authorize?: false)

    %{publisher_slug: publisher.slug, series_slug: series.slug}
  end

  defp create_series_membership! do
    suffix = System.unique_integer([:positive])

    publisher =
      Publisher
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.slug == "deep-vellum"))

    work =
      Work
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.slug == "deep-vellum-immigrant"))

    series =
      Series
      |> Ash.Changeset.for_create(:create, %{
        title: "Performance Test Series #{suffix}",
        slug: "performance-test-series-#{suffix}",
        publisher_id: publisher.id
      })
      |> Ash.create!(authorize?: false)

    SeriesMembership
    |> Ash.Changeset.for_create(:create, %{
      series_id: series.id,
      work_id: work.id,
      position: 1,
      label: "1"
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_filter_contract_edition! do
    suffix = System.unique_integer([:positive])

    publisher =
      Publisher
      |> Ash.Changeset.for_create(:create, %{
        name: "Facet Contract Press #{suffix}",
        slug: "facet-contract-press-#{suffix}"
      })
      |> Ash.create!(authorize?: false)

    work =
      Work
      |> Ash.Changeset.for_create(:create, %{
        title: "Facet Contract Novel",
        slug: "facet-contract-novel-#{suffix}",
        publication_state: "published",
        original_language_code: "spa",
        subjects: ["contract-subject"]
      })
      |> Ash.create!(authorize?: false)

    edition =
      Edition
      |> Ash.Changeset.for_create(:create, %{
        title: "Facet Contract Novel",
        slug: "facet-contract-novel-paperback-#{suffix}",
        format: "paperback",
        published_on: ~D[2026-05-01],
        language_code: "eng",
        work_id: work.id,
        publisher_id: publisher.id
      })
      |> Ash.create!(authorize?: false)

    author = create_contributor!("Facet Contract Author", "facet-contract-author-#{suffix}")

    translator =
      create_contributor!("Facet Contract Translator", "facet-contract-translator-#{suffix}")

    create_contribution!(work.id, author.id, "author", 1)
    create_contribution!(work.id, translator.id, "translator", 2)

    series =
      Series
      |> Ash.Changeset.for_create(:create, %{
        title: "Facet Contract Series",
        slug: "facet-contract-series-#{suffix}",
        publisher_id: publisher.id
      })
      |> Ash.create!(authorize?: false)

    SeriesMembership
    |> Ash.Changeset.for_create(:create, %{series_id: series.id, work_id: work.id, position: 1})
    |> Ash.create!(authorize?: false)

    Identifier
    |> Ash.Changeset.for_create(:create, %{
      identifier_type: "isbn_13",
      value: "979000001#{String.pad_leading(to_string(rem(suffix, 10_000)), 4, "0")}",
      edition_id: edition.id
    })
    |> Ash.create!(authorize?: false)

    Hiraeth.Sources.SourceRecord
    |> Ash.Changeset.for_create(:create, %{
      provider: "deep_vellum_official_store",
      source_type: "publisher_dataset",
      source_uri: "https://store.deepvellum.org/products/facet-contract-#{suffix}",
      file_checksum: "facet-contract-#{suffix}",
      license_note: "test source fixture",
      imported_at: DateTime.utc_now(:second),
      raw_payload: %{
        "edition" => %{
          "isbn_13" => "979000001#{String.pad_leading(to_string(rem(suffix, 10_000)), 4, "0")}"
        },
        "displayed_fields" => ["title"]
      }
    })
    |> Ash.create!(authorize?: false)

    %{
      q: "Facet Contract",
      publisher: "facet-contract-press-#{suffix}",
      role: "translator",
      contributor: "facet-contract-translator-#{suffix}",
      format: "paperback",
      language: "eng",
      subject: "contract-subject",
      series: "facet-contract-series-#{suffix}",
      year: "2026",
      sort: "title"
    }
  end

  defp create_enriched_projection_edition! do
    suffix = System.unique_integer([:positive])
    isbn = "979000002#{String.pad_leading(to_string(rem(suffix, 10_000)), 4, "0")}"

    publisher =
      Publisher
      |> Ash.Changeset.for_create(:create, %{
        name: "Projection Contract Press #{suffix}",
        slug: "projection-contract-press-#{suffix}"
      })
      |> Ash.create!(authorize?: false)

    work =
      Work
      |> Ash.Changeset.for_create(:create, %{
        title: "Projection Contract Novel",
        slug: "projection-contract-novel-#{suffix}",
        publication_state: "published",
        original_title: "Roman de projection",
        original_language_code: "fra",
        subjects: ["projection-subject", "metadata-contract"]
      })
      |> Ash.create!(authorize?: false)

    edition =
      Edition
      |> Ash.Changeset.for_create(:create, %{
        title: "Projection Contract Novel",
        slug: "projection-contract-novel-paperback-#{suffix}",
        format: "paperback",
        language_code: "eng",
        page_count: 321,
        height_mm: 203,
        width_mm: 127,
        depth_mm: 24,
        published_on: ~D[2026-06-01],
        work_id: work.id,
        publisher_id: publisher.id
      })
      |> Ash.create!(authorize?: false)

    Identifier
    |> Ash.Changeset.for_create(:create, %{
      identifier_type: "isbn_13",
      value: isbn,
      edition_id: edition.id
    })
    |> Ash.create!(authorize?: false)

    Hiraeth.Sources.SourceRecord
    |> Ash.Changeset.for_create(:create, %{
      provider: "deep_vellum_official_store",
      source_type: "publisher_dataset",
      source_uri: "https://store.deepvellum.org/products/projection-contract-#{suffix}",
      file_checksum: "projection-contract-#{suffix}",
      license_note: "test source fixture",
      imported_at: DateTime.utc_now(:second),
      raw_payload: %{
        "edition" => %{"isbn_13" => isbn},
        "displayed_fields" => ["title", "page_count"],
        "field_sources" => %{
          "page_count" => %{
            "provider" => "deep_vellum_official_store",
            "source_uri" => "https://store.deepvellum.org/products/projection-contract-#{suffix}",
            "source_type" => "publisher_dataset",
            "rights_basis" => "test source fixture"
          }
        }
      }
    })
    |> Ash.create!(authorize?: false)

    edition.slug
  end

  defp create_contributor!(name, slug) do
    Hiraeth.Catalog.Contributor
    |> Ash.Changeset.for_create(:create, %{
      display_name: name,
      sort_name: name,
      slug: slug
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_contribution!(work_id, contributor_id, role, position) do
    Hiraeth.Catalog.Contribution
    |> Ash.Changeset.for_create(:create, %{
      work_id: work_id,
      contributor_id: contributor_id,
      role: role,
      position: position
    })
    |> Ash.create!(authorize?: false)
  end

  defp warm_measure(fun) do
    _warm = QueryCounting.measure(fun)
    QueryCounting.measure(fun)
  end

  defp broad_edition_projection_query?(measurement) do
    Enum.any?(measurement.queries, fn query ->
      edition_projection_query?(query) and
        not String.contains?(query, "where e.")
    end)
  end

  defp scoped_edition_projection_query?(measurement, scope_sql) do
    Enum.any?(measurement.queries, fn query ->
      edition_projection_query?(query) and String.contains?(query, scope_sql)
    end)
  end

  defp edition_projection_query?(query) do
    query =~ ~r/select\s+e\.id,\s+e\.work_id,/i
  end
end
