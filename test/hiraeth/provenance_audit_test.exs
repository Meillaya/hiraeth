defmodule Hiraeth.ProvenanceAuditTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Accounts.User
  alias Hiraeth.Audit.AuditEvent
  alias Hiraeth.Catalog.{Edition, Publisher, Work}
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}

  @password "correct horse battery staple"

  setup do
    admin =
      User
      |> Ash.Changeset.for_create(:seed_admin, %{
        email: "provenance-audit-#{System.unique_integer([:positive])}@example.test",
        password: @password,
        display_name: "Provenance Audit Admin"
      })
      |> Ash.create!(authorize?: false)

    %{
      admin: admin,
      output_dir: "artifacts/qa/provenance-test/#{System.unique_integer([:positive])}"
    }
  end

  test "exports source ledger CSV with source, hash, and license columns for seeded data", %{
    output_dir: output_dir
  } do
    Hiraeth.DemoFixtures.seed!()

    audit = Hiraeth.ProvenanceAudit.run!(output_dir: output_dir, fail_on_error?: true)

    csv_path = Path.join(output_dir, "source-ledger.csv")
    json_path = Path.join(output_dir, "audit-provenance.json")

    assert audit.missing_provenance == []
    assert audit.invalid_public_covers == []
    assert audit.source_ledger_rows > 0
    assert File.exists?(csv_path)
    assert File.exists?(json_path)

    csv = File.read!(csv_path)

    assert csv =~
             "entity,field,value_hash,source_record_id,source_uri,provider,source_type,license_or_rights_basis,import_run_id"

    assert csv =~ "edition:the-orchard-of-minor-moons-paperback,edition.title,"
    assert csv =~ "local_demo_fixture"
  end

  test "public cover missing rights basis fails the provenance gate", %{
    admin: admin,
    output_dir: output_dir
  } do
    Hiraeth.DemoFixtures.seed!()
    edition = edition!(admin)

    cover_id = Ash.UUID.generate()

    Hiraeth.Repo.insert_all("cover_assets", [
      %{
        id: dump_uuid!(cover_id),
        source_url: "https://covers.example.test/missing-rights.jpg",
        provider: "fixture-covers",
        rights_basis: "",
        cache_policy: "link_only",
        takedown_state: "visible"
      }
    ])

    Hiraeth.Repo.insert_all("cover_assignments", [
      %{
        id: dump_uuid!(Ash.UUID.generate()),
        edition_id: dump_uuid!(edition.id),
        cover_asset_id: dump_uuid!(cover_id),
        position: 1,
        visible?: true
      }
    ])

    audit = Hiraeth.ProvenanceAudit.audit!()
    assert [%{reason: reason}] = audit.invalid_public_covers
    assert reason =~ "rights basis"

    assert_raise RuntimeError, ~r/provenance audit failed/, fn ->
      Hiraeth.ProvenanceAudit.run!(output_dir: output_dir, fail_on_error?: true)
    end
  end

  test "takedown audit trail is exported and audit events are append-only", %{
    admin: admin,
    output_dir: output_dir
  } do
    Hiraeth.DemoFixtures.seed!()
    edition = edition!(admin)

    cover =
      cover_asset!(admin, %{
        source_url: "https://covers.example.test/hidden.jpg",
        takedown_state: "hidden"
      })

    assignment!(admin, edition, cover)

    event =
      AuditEvent
      |> Ash.Changeset.for_create(:create, %{
        event_type: "cover_takedown",
        entity_type: "cover_asset",
        entity_id: cover.id,
        metadata: %{"reason" => "fixture takedown"},
        occurred_at: DateTime.utc_now(:second)
      })
      |> Ash.create!(actor: admin)

    audit = Hiraeth.ProvenanceAudit.run!(output_dir: output_dir, fail_on_error?: false)

    assert Enum.any?(
             audit.takedown_audit,
             &(&1.cover_asset_id == cover.id and &1.takedown_state == "hidden")
           )

    assert Enum.any?(
             audit.audit_events,
             &(&1.id == event.id and &1.event_type == "cover_takedown")
           )

    assert File.read!(Path.join(output_dir, "takedown-audit.csv")) =~ "fixture takedown"

    refute Ash.Resource.Info.action(AuditEvent, :update)
    refute Ash.Resource.Info.action(AuditEvent, :destroy)
  end

  defp edition!(admin) do
    publisher =
      Publisher
      |> Ash.Changeset.for_create(:create, %{
        name: "Audit Press #{System.unique_integer([:positive])}",
        slug: unique_slug("audit-press")
      })
      |> Ash.create!(actor: admin)

    work =
      Work
      |> Ash.Changeset.for_create(:create, %{title: "Audit Work", slug: unique_slug("audit-work")})
      |> Ash.create!(actor: admin)

    Edition
    |> Ash.Changeset.for_create(:create, %{
      title: "Audit Edition",
      slug: unique_slug("audit-edition"),
      work_id: work.id,
      publisher_id: publisher.id
    })
    |> Ash.create!(actor: admin)
  end

  defp cover_asset!(admin, attrs) do
    attrs =
      Map.merge(
        %{
          source_url: "https://covers.example.test/#{System.unique_integer([:positive])}.jpg",
          provider: "fixture-covers",
          rights_basis: "provider_link_allowed",
          cache_policy: "link_only",
          attribution_text: "Fixture cover provider",
          takedown_state: "visible"
        },
        attrs
      )

    CoverAsset
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: admin)
  end

  defp assignment!(admin, edition, cover_asset) do
    CoverAssignment
    |> Ash.Changeset.for_create(:create, %{
      edition_id: edition.id,
      cover_asset_id: cover_asset.id,
      position: 1,
      visible?: true
    })
    |> Ash.create!(actor: admin)
  end

  defp dump_uuid!(uuid) do
    {:ok, dumped} = Ecto.UUID.dump(uuid)
    dumped
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
