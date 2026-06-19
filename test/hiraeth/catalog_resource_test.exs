defmodule Hiraeth.CatalogResourceTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Catalog.{
    Contributor,
    Contribution,
    Edition,
    Identifier,
    Publisher,
    Series,
    SeriesMembership,
    Work
  }

  setup do
    %{admin: trusted_catalog_actor()}
  end

  test "work and edition are separate; ISBNs belong to editions and are unique", %{admin: admin} do
    publisher =
      create!(Publisher, %{name: "Fictional Archive", slug: unique_slug("publisher")}, admin)

    work = create!(Work, %{title: "A Work", slug: unique_slug("work")}, admin)

    edition =
      create!(
        Edition,
        %{
          title: "A Work: First Edition",
          slug: unique_slug("edition"),
          work_id: work.id,
          publisher_id: publisher.id,
          format: "paperback"
        },
        admin
      )

    identifier =
      create!(
        Identifier,
        %{identifier_type: "isbn_13", value: "9780000000001", edition_id: edition.id},
        admin
      )

    assert edition.work_id == work.id
    assert identifier.edition_id == edition.id

    duplicate =
      Identifier
      |> Ash.Changeset.for_create(:create, %{
        identifier_type: "isbn_13",
        value: "9780000000001",
        edition_id: edition.id
      })
      |> Ash.create(actor: admin)

    assert {:error, error} = duplicate
    assert Exception.message(error) =~ "has already been taken"
  end

  test "works store sourced public prose metadata for catalog display", %{admin: admin} do
    work =
      create!(
        Work,
        %{
          title: "Sourced Prose Work",
          slug: unique_slug("sourced-prose-work"),
          description: "A sourced public synopsis.",
          storefront_url: "https://archipelagobooks.org/book/sourced-prose-work/",
          editorial_praise: [
            %{
              "quote" => "A precise sourced praise excerpt.",
              "source" => "Publisher official page",
              "source_uri" => "https://archipelagobooks.org/book/sourced-prose-work/"
            }
          ]
        },
        admin
      )

    assert work.description == "A sourced public synopsis."
    assert work.storefront_url == "https://archipelagobooks.org/book/sourced-prose-work/"

    assert [praise] = work.editorial_praise
    assert praise["quote"] == "A precise sourced praise excerpt."
    assert praise["source_uri"] == "https://archipelagobooks.org/book/sourced-prose-work/"

    updated =
      work
      |> Ash.Changeset.for_update(:update, %{
        description: "Updated sourced synopsis.",
        original_title: "Titre mis à jour",
        original_language_code: "fra",
        subjects: ["Updated subject"]
      })
      |> Ash.update!(actor: admin)

    assert updated.description == "Updated sourced synopsis."
    assert updated.original_title == "Titre mis à jour"
    assert updated.original_language_code == "fra"
    assert updated.subjects == ["Updated subject"]
  end

  test "works store nullable source-backed bibliographic metadata", %{admin: admin} do
    work =
      create!(
        Work,
        %{
          title: "Source Metadata Work",
          slug: unique_slug("source-metadata-work"),
          original_title: "Titre source",
          original_language_code: "fra",
          subjects: ["French literature", "Experimental fiction"]
        },
        admin
      )

    assert work.original_title == "Titre source"
    assert work.original_language_code == "fra"
    assert work.subjects == ["French literature", "Experimental fiction"]

    minimal = create!(Work, %{title: "Minimal Metadata Work", slug: unique_slug("work")}, admin)

    assert minimal.original_title == nil
    assert minimal.original_language_code == nil
    assert minimal.subjects == []
  end

  test "editions store nullable source-backed format metadata in millimetres", %{admin: admin} do
    publisher =
      create!(Publisher, %{name: "Metadata Press", slug: unique_slug("publisher")}, admin)

    work = create!(Work, %{title: "Measured Work", slug: unique_slug("work")}, admin)

    edition =
      create!(
        Edition,
        %{
          title: "Measured Work",
          slug: unique_slug("edition"),
          work_id: work.id,
          publisher_id: publisher.id,
          format: "paperback",
          language_code: "eng",
          page_count: 224,
          height_mm: 203,
          width_mm: 127,
          depth_mm: 18
        },
        admin
      )

    assert edition.language_code == "eng"
    assert edition.page_count == 224
    assert edition.height_mm == 203
    assert edition.width_mm == 127
    assert edition.depth_mm == 18

    minimal =
      create!(
        Edition,
        %{
          title: "Unmeasured Work",
          slug: unique_slug("edition"),
          work_id: work.id,
          publisher_id: publisher.id
        },
        admin
      )

    assert minimal.language_code == nil
    assert minimal.page_count == nil
    assert minimal.height_mm == nil
    assert minimal.width_mm == nil
    assert minimal.depth_mm == nil

    updated =
      minimal
      |> Ash.Changeset.for_update(:update, %{
        language_code: "spa",
        page_count: 144,
        height_mm: 198,
        width_mm: 129,
        depth_mm: 16
      })
      |> Ash.update!(actor: admin)

    assert updated.language_code == "spa"
    assert updated.page_count == 144
    assert updated.height_mm == 198
    assert updated.width_mm == 129
    assert updated.depth_mm == 16
  end

  test "edition catalog-edge create accepts source-backed format metadata", %{admin: admin} do
    publisher =
      create!(Publisher, %{name: "Nested Metadata Press", slug: unique_slug("publisher")}, admin)

    work = create!(Work, %{title: "Nested Metadata Work", slug: unique_slug("work")}, admin)

    edition =
      Edition
      |> Ash.Changeset.for_create(:create_with_catalog_edges, %{
        title: "Nested Metadata Work",
        slug: unique_slug("edition"),
        work_id: work.id,
        publisher_id: publisher.id,
        format: "paperback",
        language_code: "ita",
        page_count: 192,
        height_mm: 210,
        width_mm: 135,
        depth_mm: 20,
        contributor: %{
          "display_name" => "Nested Author",
          "sort_name" => "Author, Nested",
          "slug" => unique_slug("nested-author"),
          "role" => "author"
        },
        identifier: %{
          "identifier_type" => "isbn_13",
          "value" => "9787000000209"
        }
      })
      |> Ash.create!(actor: admin)

    assert edition.language_code == "ita"
    assert edition.page_count == 192
    assert edition.height_mm == 210
    assert edition.width_mm == 135
    assert edition.depth_mm == 20
  end

  test "edition physical metadata requires positive millimetre and page values", %{admin: admin} do
    publisher =
      create!(Publisher, %{name: "Positive Press", slug: unique_slug("publisher")}, admin)

    work = create!(Work, %{title: "Positive Work", slug: unique_slug("work")}, admin)

    invalid =
      Edition
      |> Ash.Changeset.for_create(:create, %{
        title: "Invalid Dimensions",
        slug: unique_slug("edition"),
        work_id: work.id,
        publisher_id: publisher.id,
        page_count: 0,
        height_mm: -1,
        width_mm: 0,
        depth_mm: -4
      })
      |> Ash.create(actor: admin)

    assert {:error, error} = invalid
    message = Exception.message(error)
    assert message =~ "page_count"
    assert message =~ "height_mm"
    assert message =~ "width_mm"
    assert message =~ "depth_mm"

    valid =
      create!(
        Edition,
        %{
          title: "Valid Dimensions",
          slug: unique_slug("edition"),
          work_id: work.id,
          publisher_id: publisher.id,
          page_count: 1,
          height_mm: 1,
          width_mm: 1,
          depth_mm: 1
        },
        admin
      )

    invalid_update =
      valid
      |> Ash.Changeset.for_update(:update, %{page_count: 0, height_mm: -2})
      |> Ash.update(actor: admin)

    assert {:error, update_error} = invalid_update
    update_message = Exception.message(update_error)
    assert update_message =~ "page_count"
    assert update_message =~ "height_mm"
  end

  test "language metadata must be nullable ISO 639-3 codes", %{admin: admin} do
    publisher =
      create!(Publisher, %{name: "Language Press", slug: unique_slug("publisher")}, admin)

    work = create!(Work, %{title: "Language Work", slug: unique_slug("work")}, admin)

    invalid_work =
      Work
      |> Ash.Changeset.for_create(:create, %{
        title: "Invalid Original Language",
        slug: unique_slug("work"),
        original_language_code: "english"
      })
      |> Ash.create(actor: admin)

    assert {:error, work_error} = invalid_work
    assert Exception.message(work_error) =~ "original_language_code"

    valid_work =
      create!(
        Work,
        %{
          title: "Valid Original Language",
          slug: unique_slug("work"),
          original_language_code: "jpn"
        },
        admin
      )

    invalid_work_update =
      valid_work
      |> Ash.Changeset.for_update(:update, %{original_language_code: "JP"})
      |> Ash.update(actor: admin)

    assert {:error, work_update_error} = invalid_work_update
    assert Exception.message(work_update_error) =~ "original_language_code"

    invalid_edition =
      Edition
      |> Ash.Changeset.for_create(:create, %{
        title: "Invalid Edition Language",
        slug: unique_slug("edition"),
        work_id: work.id,
        publisher_id: publisher.id,
        language_code: "en"
      })
      |> Ash.create(actor: admin)

    assert {:error, edition_error} = invalid_edition
    assert Exception.message(edition_error) =~ "language_code"

    invalid_nested =
      Edition
      |> Ash.Changeset.for_create(:create_with_catalog_edges, %{
        title: "Invalid Nested Language",
        slug: unique_slug("edition"),
        work_id: work.id,
        publisher_id: publisher.id,
        language_code: "italian",
        contributor: %{"display_name" => "Language Author", "role" => "author"},
        identifier: %{"identifier_type" => "isbn_13", "value" => "9787000000216"}
      })
      |> Ash.create(actor: admin)

    assert {:error, nested_error} = invalid_nested
    assert Exception.message(nested_error) =~ "language_code"
  end

  test "contributors are assigned by contribution role", %{admin: admin} do
    publisher = create!(Publisher, %{name: "Role Press", slug: unique_slug("publisher")}, admin)
    work = create!(Work, %{title: "Translated Work", slug: unique_slug("work")}, admin)

    edition =
      create!(
        Edition,
        %{
          title: "Translated Work",
          slug: unique_slug("edition"),
          work_id: work.id,
          publisher_id: publisher.id
        },
        admin
      )

    contributor =
      create!(
        Contributor,
        %{
          display_name: "Ada Translator",
          sort_name: "Translator, Ada",
          slug: unique_slug("contributor")
        },
        admin
      )

    contribution =
      create!(
        Contribution,
        %{
          contributor_id: contributor.id,
          edition_id: edition.id,
          role: "translator",
          position: 1
        },
        admin
      )

    assert contribution.contributor_id == contributor.id
    assert contribution.edition_id == edition.id
    assert contribution.role == "translator"
  end

  test "series memberships preserve explicit ordering", %{admin: admin} do
    publisher = create!(Publisher, %{name: "Series Press", slug: unique_slug("publisher")}, admin)

    series =
      create!(
        Series,
        %{title: "Archive Series", slug: unique_slug("series"), publisher_id: publisher.id},
        admin
      )

    first = create!(Work, %{title: "First Work", slug: unique_slug("work")}, admin)
    second = create!(Work, %{title: "Second Work", slug: unique_slug("work")}, admin)

    create!(
      SeriesMembership,
      %{series_id: series.id, work_id: second.id, position: 2, label: "2"},
      admin
    )

    create!(
      SeriesMembership,
      %{series_id: series.id, work_id: first.id, position: 1, label: "1"},
      admin
    )

    ordered_work_ids =
      SeriesMembership
      |> Ash.Query.for_read(:by_series, %{series_id: series.id})
      |> Ash.read!(actor: admin)
      |> Enum.map(& &1.work_id)

    assert ordered_work_ids == [first.id, second.id]
  end

  test "catalog policies allow public reads and require trusted catalog writers for writes", %{
    admin: admin
  } do
    publisher =
      create!(Publisher, %{name: "Readable Press", slug: unique_slug("publisher")}, admin)

    public_publishers =
      Publisher
      |> Ash.Query.for_read(:read)
      |> Ash.read!(authorize?: true)

    assert Enum.any?(public_publishers, &(&1.id == publisher.id))

    assert {:error, error} =
             Publisher
             |> Ash.Changeset.for_create(:create, %{
               name: "Forbidden Press",
               slug: unique_slug("publisher")
             })
             |> Ash.create()

    assert Exception.message(error) =~ "forbidden"
  end

  defp create!(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: actor)
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
