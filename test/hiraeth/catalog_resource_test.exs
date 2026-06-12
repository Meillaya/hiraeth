defmodule Hiraeth.CatalogResourceTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Accounts.User

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
    admin =
      User
      |> Ash.Changeset.for_create(:seed_admin, %{
        email: "catalog-admin-#{System.unique_integer([:positive])}@example.test",
        password: "correct horse battery staple",
        display_name: "Catalog Admin"
      })
      |> Ash.create!(authorize?: false)

    %{admin: admin}
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

  test "catalog policies allow public reads and require admin actors for writes", %{admin: admin} do
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
