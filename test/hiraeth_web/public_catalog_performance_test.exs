defmodule HiraethWeb.PublicCatalogPerformanceTest do
  use HiraethWeb.ConnCase, async: false

  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Series, SeriesMembership, Work}
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.QueryCounting
  alias HiraethWeb.PublicCatalog

  @list_query_budget 8
  @detail_query_budget 8
  @directory_query_budget 8
  @warm_elapsed_budget_microseconds 175_000

  setup_all do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Hiraeth.Repo, fn ->
      Hiraeth.RealCatalogFixtures.seed!()
    end)

    :ok
  end

  test "paged public catalog excludes records without source provenance" do
    fixture = create_source_less_edition!()

    page = PublicCatalog.book_page("Source Less Invisible", 1)

    assert page.total_count == 0
    assert page.entries == []
    assert PublicCatalog.book(fixture.work_slug) == nil
    assert PublicCatalog.book(fixture.edition_slug) == nil
    assert PublicCatalog.edition(fixture.edition_slug) == nil
  end

  test "publisher and series directories exclude records without source provenance" do
    %{publisher_slug: publisher_slug, series_slug: series_slug} = create_source_less_edition!()

    refute Enum.any?(PublicCatalog.publishers(), &(&1.slug == publisher_slug))
    assert PublicCatalog.publisher(publisher_slug) == nil

    refute Enum.any?(PublicCatalog.series(), &(&1.slug == series_slug))
    assert PublicCatalog.series_by_slug(series_slug) == nil
  end

  test "publisher directory ignores stale pre-TTL cache entries and exposes cached cover samples" do
    previous_cache? = Application.get_env(:hiraeth, :public_catalog_cache)
    previous_ttl = Application.get_env(:hiraeth, :public_catalog_cache_ttl_ms)
    legacy_cache_key = {PublicCatalog, :cache, {:publishers}}

    Application.put_env(:hiraeth, :public_catalog_cache, true)
    Application.put_env(:hiraeth, :public_catalog_cache_ttl_ms, :infinity)
    PublicCatalog.clear_cache()

    on_exit(fn ->
      :persistent_term.erase(legacy_cache_key)
      PublicCatalog.clear_cache()
      Application.put_env(:hiraeth, :public_catalog_cache, previous_cache?)

      if is_nil(previous_ttl) do
        Application.delete_env(:hiraeth, :public_catalog_cache_ttl_ms)
      else
        Application.put_env(:hiraeth, :public_catalog_cache_ttl_ms, previous_ttl)
      end
    end)

    %{publisher_slug: publisher_slug, title: title} = create_cached_cover_publisher!()

    :persistent_term.put(legacy_cache_key, [
      %{
        id: Ecto.UUID.generate(),
        name: "Legacy Placeholder Press",
        slug: "legacy-placeholder-press",
        description: nil,
        editions: [],
        editions_count: 1,
        cover_sample: nil,
        groupings: %{}
      }
    ])

    publisher = Enum.find(PublicCatalog.publishers(), &(&1.slug == publisher_slug))

    assert publisher.cover_sample.title == title

    cover_url =
      publisher.cover_sample.cover.thumbnail_url || publisher.cover_sample.cover.public_url

    assert String.starts_with?(cover_url, "/covers/cache/")
  end

  test "grouped public catalog search is fast and returns no duplicate book cards" do
    assert Code.ensure_loaded?(PublicCatalog)

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

    assert page.total_count >= 2_790
    assert length(page.entries) == PublicCatalog.page_size()
    assert measurement.query_count <= @list_query_budget
    assert measurement.elapsed_microseconds <= @warm_elapsed_budget_microseconds
  end

  test "public title lists sort by publication date newest and upcoming first" do
    first_page = PublicCatalog.book_page(nil, 1)
    second_page = PublicCatalog.book_page(nil, 2)
    publisher = PublicCatalog.publisher("deep-vellum")
    contributor = PublicCatalog.contributor("david-bowles")

    assert_publication_date_desc(first_page.entries)
    assert_publication_date_desc(second_page.entries)
    assert_publication_date_desc(publisher.editions)
    assert_publication_date_desc(contributor.books)

    assert publication_date_rank(List.last(first_page.entries)) >=
             publication_date_rank(List.first(second_page.entries))
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

  test "public catalog projection refuses remote cover fallbacks before rendering covers" do
    slug = create_new_directions_link_only_cover_edition!()

    measurement = warm_measure(fn -> PublicCatalog.book(slug) end)

    assert %{title: "Provider Policy Cover Novel", cover: nil} = measurement.result
    assert measurement.query_count <= @detail_query_budget
    assert measurement.elapsed_microseconds <= @warm_elapsed_budget_microseconds
  end

  test "publisher and series directories have bounded query count" do
    publisher_index = warm_measure(fn -> PublicCatalog.publishers() end)
    publisher_detail = warm_measure(fn -> PublicCatalog.publisher("deep-vellum") end)
    series_index = warm_measure(fn -> PublicCatalog.series() end)

    series_detail =
      case List.first(series_index.result) do
        nil -> nil
        series -> warm_measure(fn -> PublicCatalog.series_by_slug(series.slug) end)
      end

    assert Enum.any?(publisher_index.result, &(&1.slug == "deep-vellum"))
    assert %{slug: "deep-vellum", groupings: publisher_groupings} = publisher_detail.result
    assert Enum.all?(Map.values(publisher_groupings), &(length(&1) <= 8))
    assert Enum.any?(publisher_groupings.formats, &(&1.label == "Paperback"))
    assert is_list(series_index.result)
    refute broad_edition_projection_query?(publisher_index)
    refute broad_edition_projection_query?(series_index)
    assert scoped_edition_projection_query?(publisher_detail, "where e.publisher_id = $1::uuid")

    if series_detail do
      assert scoped_edition_projection_query?(
               series_detail,
               "where e.work_id = any($1::uuid[])"
             )
    end

    for measurement <- [publisher_index, publisher_detail, series_index, series_detail],
        not is_nil(measurement) do
      assert measurement.query_count <= @directory_query_budget
      assert measurement.elapsed_microseconds <= @warm_elapsed_budget_microseconds
    end
  end

  test "public catalog ids are UTF-8 UUID strings safe for LiveView stream DOM ids" do
    page = PublicCatalog.book_page(nil, 1)
    publisher = PublicCatalog.publisher("deep-vellum")

    series =
      PublicCatalog.series()
      |> List.first()
      |> then(&(&1 && PublicCatalog.series_by_slug(&1.slug)))

    ids =
      [
        Enum.flat_map(page.entries, &[&1.id, &1.work_id]),
        [publisher.id],
        Enum.flat_map(publisher.editions, &[&1.id, &1.work_id]),
        if(series, do: [series.id], else: []),
        if(series, do: Enum.flat_map(series.editions, &[&1.id, &1.work_id]), else: [])
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

    %{
      publisher_slug: publisher.slug,
      series_slug: series.slug,
      work_slug: work.slug,
      edition_slug: edition.slug
    }
  end

  defp create_cached_cover_publisher! do
    suffix = System.unique_integer([:positive])
    isbn = "979000009#{String.pad_leading(to_string(rem(suffix, 10_000)), 4, "0")}"
    publisher_slug = "cached-cover-test-press-#{suffix}"
    work_slug = "cached-cover-test-novel-#{suffix}"
    edition_slug = "#{work_slug}-paperback-#{isbn}"
    title = "Cached Cover Test Novel #{suffix}"
    cached_path = "priv/static/covers/cache/cached-cover-test-#{suffix}.jpg"
    thumbnail_path = "priv/static/covers/cache/cached-cover-test-#{suffix}-thumb.jpg"

    publisher =
      Publisher
      |> Ash.Changeset.for_create(:create, %{
        name: "Cached Cover Test Press #{suffix}",
        slug: publisher_slug
      })
      |> Ash.create!(authorize?: false)

    work =
      Work
      |> Ash.Changeset.for_create(:create, %{
        title: title,
        slug: work_slug,
        publication_state: "published"
      })
      |> Ash.create!(authorize?: false)

    edition =
      Edition
      |> Ash.Changeset.for_create(:create, %{
        title: title,
        slug: edition_slug,
        format: "paperback",
        published_on: ~D[2026-01-01],
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
      source_uri: "https://store.deepvellum.org/products/cached-cover-test-#{suffix}",
      file_checksum: "cached-cover-test-#{suffix}",
      license_note: "test source fixture",
      source_identity: isbn,
      edition_id: edition.id,
      imported_at: DateTime.utc_now(:second),
      raw_payload: %{
        "edition" => %{"isbn_13" => isbn},
        "displayed_fields" => ["title"]
      }
    })
    |> Ash.create!(authorize?: false)

    cover =
      CoverAsset
      |> Ash.Changeset.for_create(:create, %{
        source_url: "https://cdn.shopify.com/cached-cover-test-#{suffix}.jpg",
        provider: "deep_vellum_official_store",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: cached_path,
        thumbnail_file_path: thumbnail_path,
        takedown_state: "visible"
      })
      |> Ash.create!(authorize?: false)

    CoverAssignment
    |> Ash.Changeset.for_create(:create, %{
      edition_id: edition.id,
      cover_asset_id: cover.id,
      visible?: true,
      position: 1
    })
    |> Ash.create!(authorize?: false)

    %{publisher_slug: publisher_slug, title: title, cached_path: cached_path}
  end

  defp create_filter_contract_edition! do
    suffix = System.unique_integer([:positive])
    isbn = "979000001#{String.pad_leading(to_string(rem(suffix, 10_000)), 4, "0")}"

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
      value: isbn,
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
      source_identity: isbn,
      edition_id: edition.id,
      imported_at: DateTime.utc_now(:second),
      raw_payload: %{
        "edition" => %{"isbn_13" => isbn},
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
      source_identity: isbn,
      edition_id: edition.id,
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

  defp create_new_directions_link_only_cover_edition! do
    suffix = System.unique_integer([:positive])
    isbn = "979000003#{String.pad_leading(to_string(rem(suffix, 10_000)), 4, "0")}"

    publisher =
      Publisher
      |> Ash.Changeset.for_create(:create, %{
        name: "Provider Policy Cover Press #{suffix}",
        slug: "provider-policy-cover-press-#{suffix}"
      })
      |> Ash.create!(authorize?: false)

    work =
      Work
      |> Ash.Changeset.for_create(:create, %{
        title: "Provider Policy Cover Novel",
        slug: "provider-policy-cover-novel-#{suffix}",
        publication_state: "published"
      })
      |> Ash.create!(authorize?: false)

    edition =
      Edition
      |> Ash.Changeset.for_create(:create, %{
        title: "Provider Policy Cover Novel",
        slug: "provider-policy-cover-novel-paperback-#{suffix}",
        format: "paperback",
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
      provider: "new_directions_official_site",
      source_type: "publisher_dataset",
      source_uri: "https://www.ndbooks.com/book/provider-policy-cover-#{suffix}/",
      file_checksum: "provider-policy-cover-#{suffix}",
      license_note: "test source fixture",
      source_identity: isbn,
      edition_id: edition.id,
      imported_at: DateTime.utc_now(:second),
      raw_payload: %{
        "edition" => %{"isbn_13" => isbn},
        "displayed_fields" => ["title"]
      }
    })
    |> Ash.create!(authorize?: false)

    cover =
      CoverAsset
      |> Ash.Changeset.for_create(:create, %{
        source_url: "https://cdn.sanity.io/images/provider-policy-cover-#{suffix}.jpg",
        provider: "new_directions_official_site",
        rights_basis: "provider_link_allowed",
        cache_policy: "link_only",
        cached_file_path: nil,
        thumbnail_file_path: nil
      })
      |> Ash.create!(authorize?: false)

    CoverAssignment
    |> Ash.Changeset.for_create(:create, %{
      edition_id: edition.id,
      cover_asset_id: cover.id,
      visible?: true,
      position: 1
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

  defp assert_publication_date_desc(entries) do
    assert entries != []

    ranks = Enum.map(entries, &publication_date_rank/1)

    assert ranks == Enum.sort(ranks, :desc)
  end

  defp publication_date_rank(%{published_on: %Date{} = date}), do: Date.to_gregorian_days(date)
  defp publication_date_rank(_entry), do: Date.to_gregorian_days(~D[0001-01-01])

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
