defmodule Hiraeth.DemoFixtures do
  @moduledoc """
  Provenance-safe fictional demo catalog fixtures for local development and tests.

  The records in this module are intentionally invented. They are not scraped,
  copied publisher metadata, marketing prose, or live catalog descriptions.
  """

  alias Hiraeth.Accounts.User

  alias Hiraeth.Catalog.{
    Contribution,
    Contributor,
    Edition,
    Identifier,
    Publisher,
    Series,
    SeriesMembership,
    Work
  }

  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  @provider "local_demo_fixture"
  @license_note "Fictional, manually authored demo metadata for local Hiraeth bootstrap use only."

  @fixtures [
    %{
      publisher: %{
        name: "Moth House Editions",
        slug: "moth-house-editions",
        description: "Fictional press for quiet translated novellas."
      },
      series: %{title: "Pocket Weather Library", slug: "pocket-weather-library"},
      work: %{
        title: "The Orchard of Minor Moons",
        subtitle: "A fictional catalog seed",
        slug: "the-orchard-of-minor-moons"
      },
      edition: %{
        title: "The Orchard of Minor Moons",
        subtitle: "A fictional catalog seed",
        slug: "the-orchard-of-minor-moons-paperback",
        format: "paperback"
      },
      contributor: %{
        display_name: "Iris Vale",
        sort_name: "Vale, Iris",
        slug: "iris-vale",
        role: "author"
      },
      isbn: "9780000001011"
    },
    %{
      publisher: %{
        name: "Lantern Current Books",
        slug: "lantern-current-books",
        description: "Fictional small press for essay-length inventions."
      },
      series: %{title: "Harbor Essays", slug: "harbor-essays"},
      work: %{
        title: "Index of Borrowed Harbors",
        subtitle: "Notes from an invented coast",
        slug: "index-of-borrowed-harbors"
      },
      edition: %{
        title: "Index of Borrowed Harbors",
        subtitle: "Notes from an invented coast",
        slug: "index-of-borrowed-harbors-first",
        format: "paperback"
      },
      contributor: %{
        display_name: "Noel Mar",
        sort_name: "Mar, Noel",
        slug: "noel-mar",
        role: "author"
      },
      isbn: "9780000001028"
    },
    %{
      publisher: %{
        name: "Blue Thistle Archive",
        slug: "blue-thistle-archive",
        description: "Fictional reprint house for impossible archives."
      },
      series: %{title: "Recovered Rooms", slug: "recovered-rooms"},
      work: %{
        title: "Rooms for Unwritten Letters",
        subtitle: "A made-up archival edition",
        slug: "rooms-for-unwritten-letters"
      },
      edition: %{
        title: "Rooms for Unwritten Letters",
        subtitle: "A made-up archival edition",
        slug: "rooms-for-unwritten-letters-classic",
        format: "paperback"
      },
      contributor: %{
        display_name: "Mara Quill",
        sort_name: "Quill, Mara",
        slug: "mara-quill",
        role: "author"
      },
      isbn: "9780000001035"
    },
    %{
      publisher: %{
        name: "Kite River Translations",
        slug: "kite-river-translations",
        description: "Fictional press for multilingual catalog QA."
      },
      series: %{title: "Margins Without Borders", slug: "margins-without-borders"},
      work: %{
        title: "月の余白 / مدينة الورق",
        subtitle: "A fictional multilingual edition",
        slug: "moon-margin-paper-city"
      },
      edition: %{
        title: "月の余白 / مدينة الورق",
        subtitle: "A fictional multilingual edition",
        slug: "moon-margin-paper-city-bilingual",
        format: "paperback"
      },
      contributor: %{
        display_name: "Lina Sora",
        sort_name: "Sora, Lina",
        slug: "lina-sora",
        role: "author"
      },
      isbn: "9780000001042"
    }
  ]

  def fixtures, do: @fixtures

  def seed! do
    admin = admin_actor!()

    Enum.each(@fixtures, &seed_fixture!(&1, admin))
    :ok
  end

  def audit_provenance! do
    records =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.provider == @provider))

    record_ids = MapSet.new(records, & &1.id)

    ledger_entries =
      SourceLedgerEntry
      |> Ash.read!(authorize?: false)
      |> Enum.filter(
        &(&1.event_type == "seeded_demo_fixture" and
            MapSet.member?(record_ids, &1.source_record_id))
      )

    ledger_record_ids = MapSet.new(ledger_entries, & &1.source_record_id)

    displayed_fields =
      Enum.flat_map(records, &(get_in(&1.raw_payload, ["displayed_fields"]) || []))

    %{
      provider: @provider,
      source_records: length(records),
      source_ledger_entries: length(ledger_entries),
      displayed_fields_count: length(displayed_fields),
      missing_provenance:
        records
        |> Enum.reject(&(get_in(&1.raw_payload, ["provenance"]) == @provider))
        |> Enum.map(& &1.source_uri),
      source_ledger_missing:
        records
        |> Enum.reject(&MapSet.member?(ledger_record_ids, &1.id))
        |> Enum.map(& &1.source_uri),
      long_copied_text: copied_text_findings(records)
    }
  end

  defp seed_fixture!(fixture, admin) do
    publisher =
      find_or_create!(Publisher, :slug, fixture.publisher.slug, fixture.publisher, admin)

    series =
      find_or_create!(
        Series,
        :slug,
        fixture.series.slug,
        Map.put(fixture.series, :publisher_id, publisher.id),
        admin
      )

    work =
      find_or_create!(
        Work,
        :slug,
        fixture.work.slug,
        Map.put(fixture.work, :publication_state, "published"),
        admin
      )

    edition_attrs =
      fixture.edition
      |> Map.put(:work_id, work.id)
      |> Map.put(:publisher_id, publisher.id)

    edition = find_or_create!(Edition, :slug, fixture.edition.slug, edition_attrs, admin)

    contributor =
      find_or_create!(
        Contributor,
        :slug,
        fixture.contributor.slug,
        Map.drop(fixture.contributor, [:role]),
        admin
      )

    find_or_create_contribution!(edition, contributor, fixture.contributor.role, admin)
    find_or_create_identifier!(edition, fixture.isbn, admin)
    find_or_create_series_membership!(series, work, admin)
    create_source_record!(fixture, publisher, series, work, edition, contributor, admin)
  end

  defp create_source_record!(fixture, publisher, series, work, edition, contributor, admin) do
    source_uri = "local_demo_fixture:edition:#{edition.slug}"

    existing =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.provider == @provider and &1.source_uri == source_uri))

    if existing do
      ensure_source_ledger_entry!(existing, fixture.edition.title, admin)
      existing
    else
      payload = %{
        "provenance" => @provider,
        "fixture_note" =>
          "All displayed metadata is fictional and manually authored for development.",
        "displayed_fields" => [
          "publisher.name",
          "publisher.description",
          "series.title",
          "work.title",
          "work.subtitle",
          "edition.title",
          "edition.subtitle",
          "edition.format",
          "contributor.display_name",
          "identifier.isbn_13"
        ],
        "publisher" => Map.take(publisher, [:name, :description, :slug]),
        "series" => Map.take(series, [:title, :slug]),
        "work" => Map.take(work, [:title, :subtitle, :slug]),
        "edition" => Map.take(edition, [:title, :subtitle, :slug, :format]),
        "contributor" => Map.take(contributor, [:display_name, :sort_name, :slug]),
        "identifier" => %{"isbn_13" => fixture.isbn}
      }

      source_record =
        SourceRecord
        |> Ash.Changeset.for_create(:create, %{
          provider: @provider,
          source_type: "local_demo_fixture",
          source_uri: source_uri,
          file_checksum: fixture_checksum(fixture),
          license_note: @license_note,
          raw_payload: payload,
          imported_at: DateTime.utc_now(:second)
        })
        |> Ash.create!(actor: admin)

      ensure_source_ledger_entry!(source_record, edition.title, admin)

      source_record
    end
  end

  defp find_or_create!(resource, key, value, attrs, admin) do
    resource
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(Map.get(&1, key) == value)) ||
      resource
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!(actor: admin)
  end

  defp ensure_source_ledger_entry!(source_record, edition_title, admin) do
    existing =
      SourceLedgerEntry
      |> Ash.read!(authorize?: false)
      |> Enum.find(
        &(&1.source_record_id == source_record.id and &1.event_type == "seeded_demo_fixture")
      )

    existing ||
      SourceLedgerEntry
      |> Ash.Changeset.for_create(:create, %{
        source_record_id: source_record.id,
        event_type: "seeded_demo_fixture",
        message: "Seeded fictional demo metadata for #{edition_title} from local_demo_fixture.",
        occurred_at: DateTime.utc_now(:second)
      })
      |> Ash.create!(actor: admin)
  end

  defp find_or_create_contribution!(edition, contributor, role, admin) do
    existing =
      Contribution
      |> Ash.read!(authorize?: false)
      |> Enum.find(
        &(&1.edition_id == edition.id and &1.contributor_id == contributor.id and &1.role == role)
      )

    existing ||
      Contribution
      |> Ash.Changeset.for_create(:create, %{
        edition_id: edition.id,
        contributor_id: contributor.id,
        role: role,
        position: 1
      })
      |> Ash.create!(actor: admin)
  end

  defp find_or_create_identifier!(edition, isbn, admin) do
    existing = Identifier |> Ash.read!(authorize?: false) |> Enum.find(&(&1.value == isbn))

    existing ||
      Identifier
      |> Ash.Changeset.for_create(:create, %{
        edition_id: edition.id,
        identifier_type: "isbn_13",
        value: isbn
      })
      |> Ash.create!(actor: admin)
  end

  defp find_or_create_series_membership!(series, work, admin) do
    existing =
      SeriesMembership
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.series_id == series.id and &1.work_id == work.id))

    existing ||
      SeriesMembership
      |> Ash.Changeset.for_create(:create, %{
        series_id: series.id,
        work_id: work.id,
        position: 1,
        label: "Demo"
      })
      |> Ash.create!(actor: admin)
  end

  defp admin_actor! do
    email = "demo-fixtures-admin@example.test"

    case User
         |> Ash.Changeset.for_create(:seed_admin, %{
           email: email,
           password: "correct horse battery staple",
           display_name: "Demo Fixture Admin"
         })
         |> Ash.create(authorize?: false) do
      {:ok, admin} ->
        admin

      {:error, _} ->
        User |> Ash.read!(authorize?: false) |> Enum.find(&(to_string(&1.email) == email))
    end
  end

  defp copied_text_findings(records) do
    records
    |> Enum.flat_map(&payload_strings(&1.raw_payload))
    |> Enum.filter(&(String.length(&1) > 280))
  end

  defp payload_strings(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&payload_strings/1)

  defp payload_strings(value) when is_list(value), do: Enum.flat_map(value, &payload_strings/1)
  defp payload_strings(value) when is_binary(value), do: [value]
  defp payload_strings(_value), do: []

  defp fixture_checksum(fixture) do
    :crypto.hash(:sha256, :erlang.term_to_binary(fixture)) |> Base.encode16(case: :lower)
  end
end
