defmodule Hiraeth.SourcesResourceTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Accounts.User
  alias Hiraeth.Sources
  alias Hiraeth.Sources.{CurationOverride, SourceRecord}

  setup do
    admin =
      User
      |> Ash.Changeset.for_create(:seed_admin, %{
        email: "sources-admin-#{System.unique_integer([:positive])}@example.test",
        password: "correct horse battery staple",
        display_name: "Sources Admin"
      })
      |> Ash.create!(authorize?: false)

    %{admin: admin}
  end

  test "source records preserve immutable raw payloads", %{admin: admin} do
    source = source_record!(admin, %{"title" => "Raw Publisher Title"})

    assert source.provider == "fixture-feed"
    assert source.raw_payload == %{"title" => "Raw Publisher Title"}
    assert source.license_note == "Fixture data approved for local development only"

    assert_raise ArgumentError, ~r/No such update action/i, fn ->
      source
      |> Ash.Changeset.for_update(:update, %{
        raw_payload: %{"title" => "Mutated Title"}
      })
      |> Ash.update!(actor: admin)
    end

    assert_raise ArgumentError, ~r/No such update action/i, fn ->
      source
      |> Ash.Changeset.for_update(:update, %{
        raw_payload: %{"title" => "Bypass Mutated Title"}
      })
      |> Ash.update!(authorize?: false)
    end

    reread = Ash.get!(SourceRecord, source.id, actor: admin)
    assert reread.raw_payload == %{"title" => "Raw Publisher Title"}
  end

  test "curation override resolves a field without deleting raw source value", %{admin: admin} do
    source = source_record!(admin, %{"title" => "Raw Publisher Title"})
    entity_id = Ash.UUID.generate()

    override =
      CurationOverride
      |> Ash.Changeset.for_create(
        :create,
        %{
          entity_type: "work",
          entity_id: entity_id,
          field_name: "title",
          curated_value: "Curated Display Title",
          reason: "Publisher payload used an internal working title.",
          source_record_id: source.id
        },
        actor: admin
      )
      |> Ash.create!(actor: admin)

    assert override.reviewer_id == admin.id
    assert override.source_record_id == source.id

    assert Sources.resolve_value("work", entity_id, "title", "Raw Publisher Title") ==
             "Curated Display Title"

    reread = Ash.get!(SourceRecord, source.id, actor: admin)
    assert reread.raw_payload == %{"title" => "Raw Publisher Title"}
  end

  test "override writes require an admin actor", %{admin: admin} do
    source = source_record!(admin, %{"title" => "Raw Publisher Title"})

    assert {:error, error} =
             CurationOverride
             |> Ash.Changeset.for_create(:create, %{
               entity_type: "work",
               entity_id: Ash.UUID.generate(),
               field_name: "title",
               curated_value: "Unauthorized Title",
               reason: "No reviewer actor supplied.",
               source_record_id: source.id
             })
             |> Ash.create()

    assert Exception.message(error) =~ "forbidden"
  end

  defp source_record!(admin, payload) do
    SourceRecord
    |> Ash.Changeset.for_create(:create, %{
      provider: "fixture-feed",
      source_type: "fixture",
      source_uri: "file://fixtures/catalog-#{System.unique_integer([:positive])}.json",
      file_checksum: "sha256:#{System.unique_integer([:positive])}",
      license_note: "Fixture data approved for local development only",
      raw_payload: payload,
      imported_at: DateTime.utc_now(:second)
    })
    |> Ash.create!(actor: admin)
  end
end
