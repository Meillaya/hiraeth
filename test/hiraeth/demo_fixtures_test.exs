defmodule Hiraeth.DemoFixturesTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Catalog.{Edition, Publisher, Series}
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  test "fictional demo seed creates catalog records with local provenance" do
    assert :ok = Hiraeth.DemoFixtures.seed!()

    assert Enum.any?(Ash.read!(Publisher, authorize?: false), &(&1.name == "Moth House Editions"))

    assert Enum.any?(
             Ash.read!(Series, authorize?: false),
             &(&1.title == "Pocket Weather Library")
           )

    assert Enum.any?(
             Ash.read!(Edition, authorize?: false),
             &(&1.title == "The Orchard of Minor Moons")
           )

    source_records =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.provider == "local_demo_fixture"))

    assert length(source_records) >= 3
    assert Enum.all?(source_records, &(&1.license_note =~ "Fictional"))

    assert Enum.all?(
             source_records,
             &(get_in(&1.raw_payload, ["provenance"]) == "local_demo_fixture")
           )
  end

  test "provenance audit reports zero missing displayed fields and no copied marketing prose" do
    Hiraeth.DemoFixtures.seed!()

    audit = Hiraeth.DemoFixtures.audit_provenance!()

    assert audit.missing_provenance == []
    assert audit.source_ledger_missing == []
    assert audit.long_copied_text == []
    assert audit.provider == "local_demo_fixture"
    assert audit.displayed_fields_count > 0
    assert audit.source_ledger_entries >= 3

    assert Enum.all?(
             Ash.read!(SourceLedgerEntry, authorize?: false),
             &(&1.event_type != "seeded_demo_fixture" or
                 String.contains?(&1.message, "local_demo_fixture"))
           )
  end
end
