defmodule Hiraeth.Catalog.PublicProjectionContractTest do
  use HiraethWeb.ConnCase, async: false

  alias Hiraeth.Catalog.PublicProjection
  alias HiraethWeb.PublicCatalog

  @book_keys [
    :id,
    :work_id,
    :title,
    :subtitle,
    :slug,
    :publisher,
    :publisher_slug,
    :author,
    :authors,
    :translators,
    :contributors_by_role,
    :contributor_names,
    :series_titles,
    :series_slug,
    :cover,
    :source,
    :original_title,
    :original_language_code,
    :subjects,
    :description,
    :editorial_praise,
    :praise,
    :storefront_url,
    :review_links,
    :missing_fields,
    :formats,
    :identifiers,
    :isbn,
    :sources,
    :published_on,
    :year
  ]

  @format_keys [
    :edition_slug,
    :format,
    :format_label,
    :identifiers,
    :source_identity,
    :published_on,
    :language_code,
    :page_count,
    :height_mm,
    :width_mm,
    :depth_mm,
    :dimensions
  ]

  @source_keys [
    :id,
    :source_record_id,
    :provider,
    :source_type,
    :source_uri,
    :license_note,
    :import_run_id,
    :imported_at,
    :field_sources,
    :provider_permissions,
    :source_identity
  ]

  setup_all do
    Hiraeth.CatalogCleanup.ensure_committed_catalog_fixtures!()
    :ok
  end

  test "public catalog book boundary returns typed stable projection structs" do
    assert %PublicProjection.Book{} = book = PublicCatalog.book("deep-vellum-immigrant")
    assert Map.keys(Map.from_struct(book)) |> Enum.sort() == Enum.sort(@book_keys)

    assert is_binary(book.id)
    assert is_binary(book.work_id)
    assert is_binary(book.slug)
    assert is_binary(book.title)
    assert is_list(book.subjects)
    assert is_list(book.identifiers)
    assert is_list(book.formats)
    assert is_list(book.sources)

    assert [%PublicProjection.Format{} = format | _] = book.formats
    assert Map.keys(Map.from_struct(format)) |> Enum.sort() == Enum.sort(@format_keys)
    assert is_binary(format.edition_slug)
    assert is_binary(format.format_label)
    assert is_list(format.identifiers)

    assert %PublicProjection.Source{} = book.source
    assert Map.keys(Map.from_struct(book.source)) |> Enum.sort() == Enum.sort(@source_keys)
    assert is_binary(book.source.source_record_id)
    assert is_binary(book.source.provider)
    assert is_map(book.source.field_sources)

    assert [%PublicProjection.Source{} | _] = book.sources
    assert [%PublicProjection.Contributor{} | _] = book.authors
    assert [%PublicProjection.Contributor{} | _] = book.translators
    assert %{"author" => [%PublicProjection.Contributor{} | _]} = book.contributors_by_role
  end

  test "paged public catalog entries use the same projection boundary" do
    assert %{entries: [%PublicProjection.Book{} | _], page: 1, total_count: total_count} =
             PublicCatalog.book_page(nil, 1)

    assert total_count > 0
  end
end
