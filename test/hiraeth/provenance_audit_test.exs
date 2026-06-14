defmodule Hiraeth.ProvenanceAuditTest do
  use Hiraeth.DataCase, async: false

  import Ecto.Query

  alias Hiraeth.Accounts.User
  alias Hiraeth.Audit.AuditEvent

  alias Hiraeth.Catalog.{
    Contribution,
    Edition,
    Identifier,
    Imprint,
    Publisher,
    Series,
    SeriesMembership,
    Work
  }

  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  @password "correct horse battery staple"

  setup do
    clear_catalog!()

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
    Hiraeth.RealCatalogFixtures.seed!()

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

    assert csv =~ "deep_vellum_official_store"
    assert csv =~ "publisher_dataset"
    assert csv =~ "9781646054541"

    empty_hash = :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
    real_catalog_rows = Enum.filter(audit.source_ledger, &(&1.source_type == "publisher_dataset"))

    for field <- ~w(title format published_on isbn_13) do
      rows = Enum.filter(real_catalog_rows, &(&1.field == field))
      expected_minimum = if field == "published_on", do: 145, else: 150

      assert length(rows) >= expected_minimum
      refute Enum.any?(rows, &(&1.value_hash == empty_hash))
    end
  end

  test "exports every field source entry for enriched metadata", %{
    admin: admin,
    output_dir: output_dir
  } do
    source_record =
      source_record!(admin, %{
        raw_payload: %{
          "displayed_fields" => ["title"],
          "field_sources" => rich_field_sources(),
          "work" => %{
            "title" => "Provenance Contract",
            "original_title" => "Contrat de provenance",
            "original_language_code" => "fra",
            "subjects" => ["audit", "metadata"]
          },
          "edition" => %{
            "title" => "Provenance Contract",
            "format" => "paperback",
            "language_code" => "eng",
            "page_count" => 144,
            "height_mm" => 203,
            "width_mm" => 127,
            "depth_mm" => 20
          }
        }
      })

    ledger_entry!(admin, source_record)

    audit = Hiraeth.ProvenanceAudit.run!(output_dir: output_dir, fail_on_error?: true)
    rows = Enum.filter(audit.source_ledger, &(&1.source_record_id == source_record.id))
    fields = MapSet.new(rows, & &1.field)

    for field <- Map.keys(rich_field_sources()) do
      assert field in fields
      row = Enum.find(rows, &(&1.field == field))
      assert row.provenance_source_uri == "https://example.test/provenance-contract"
      assert row.provenance_source_type == "publisher_dataset"
      assert row.license_or_rights_basis == "field-level fixture provenance"
      refute row.value_hash == empty_hash()
    end

    csv = File.read!(Path.join(output_dir, "source-ledger.csv"))
    assert csv =~ "provenance_source_uri"
    assert csv =~ "work.original_language_code"
    assert csv =~ "edition.page_count"
  end

  test "exports cover cache decision rows for public cover assets", %{
    admin: admin,
    output_dir: output_dir
  } do
    File.mkdir_p!("priv/static/covers/cache")
    File.write!("priv/static/covers/cache/provenance-cache.jpg", "fixture cover")
    File.write!("priv/static/covers/cache/provenance-cache-thumb.jpg", "fixture thumbnail")

    on_exit(fn ->
      File.rm("priv/static/covers/cache/provenance-cache.jpg")
      File.rm("priv/static/covers/cache/provenance-cache-thumb.jpg")
    end)

    cover =
      cover_asset!(admin, %{
        source_url: "https://cdn.shopify.com/s/files/1/0433/1651/0883/files/provenance-cache.jpg",
        provider: "deep_vellum_official_store",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed",
        cached_file_path: "priv/static/covers/cache/provenance-cache.jpg",
        thumbnail_file_path: "priv/static/covers/cache/provenance-cache-thumb.jpg",
        cached_at: DateTime.utc_now(:second)
      })

    audit = Hiraeth.ProvenanceAudit.run!(output_dir: output_dir, fail_on_error?: true)

    assert [
             %{
               cover_asset_id: cover_id,
               cache_policy: "cache_allowed",
               cache_decision: "cached_public_cover",
               provenance_valid?: true
             }
           ] = Enum.filter(audit.cover_cache_audit, &(&1.cover_asset_id == cover.id))

    assert cover_id == cover.id

    csv = File.read!(Path.join(output_dir, "cover-cache-audit.csv"))
    assert csv =~ "cover_asset_id,provider,cache_policy,cache_decision"
    assert csv =~ "cached_public_cover"
  end

  test "public cover missing rights basis fails the provenance gate", %{
    admin: admin,
    output_dir: output_dir
  } do
    Hiraeth.RealCatalogFixtures.seed!()
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

  test "public cover with unsafe URL policy fails the provenance gate", %{
    admin: admin
  } do
    Hiraeth.RealCatalogFixtures.seed!()
    edition = edition!(admin)

    for {source_url, provider, cache_policy, reason_fragment} <- [
          {
            "http://cdn.shopify.com/s/files/1/0433/1651/0883/files/insecure.jpg",
            "deep_vellum_official_store",
            "link_only",
            "HTTPS"
          },
          {
            "https://evil.example.test/cover.jpg",
            "deep_vellum_official_store",
            "link_only",
            "allowlisted"
          },
          {
            "https://cdn.shopify.com/s/files/1/0433/1651/0883/files/cached.jpg",
            "deep_vellum_official_store",
            "link_only",
            "cache file path"
          }
        ] do
      cover =
        cover_asset!(admin, %{
          source_url: source_url,
          provider: provider,
          cache_policy: cache_policy
        })

      maybe_set_unsafe_cached_file!(cover, reason_fragment)
      assignment!(admin, edition, cover)

      audit = Hiraeth.ProvenanceAudit.audit!()

      assert Enum.any?(
               audit.invalid_public_covers,
               &(&1.cover_asset_id == cover.id and String.contains?(&1.reason, reason_fragment))
             )
    end
  end

  test "takedown audit trail is exported and audit events are append-only", %{
    admin: admin,
    output_dir: output_dir
  } do
    Hiraeth.RealCatalogFixtures.seed!()
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

  defp edition!(_admin) do
    Edition
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.slug == "deep-vellum-immigrant-paperback-9781646054541")) ||
      raise "real catalog edition missing; seed real catalog first"
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

  defp maybe_set_unsafe_cached_file!(cover, "cache file path") do
    Hiraeth.Repo.update_all(
      from(c in CoverAsset, where: c.id == ^cover.id),
      set: [cached_file_path: "priv/static/covers/unsafe.jpg"]
    )
  end

  defp maybe_set_unsafe_cached_file!(_cover, _reason_fragment), do: :ok

  defp dump_uuid!(uuid) do
    {:ok, dumped} = Ecto.UUID.dump(uuid)
    dumped
  end

  defp source_record!(admin, attrs) do
    attrs =
      Map.merge(
        %{
          provider: "deep_vellum_official_store",
          source_type: "publisher_dataset",
          source_uri: "https://store.deepvellum.org/products/provenance-contract",
          file_checksum: "provenance-contract",
          license_note: "record-level fixture provenance",
          imported_at: DateTime.utc_now(:second),
          raw_payload: %{}
        },
        attrs
      )

    SourceRecord
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: admin)
  end

  defp ledger_entry!(admin, source_record) do
    SourceLedgerEntry
    |> Ash.Changeset.for_create(:create, %{
      source_record_id: source_record.id,
      event_type: "ingested",
      message: "fixture provenance ledger",
      occurred_at: DateTime.utc_now(:second)
    })
    |> Ash.create!(actor: admin)
  end

  defp rich_field_sources do
    for field <- ~w(
          title
          work.original_title
          work.original_language_code
          work.subjects
          edition.language_code
          edition.page_count
          edition.height_mm
          edition.width_mm
          edition.depth_mm
        ),
        into: %{} do
      {field,
       %{
         "provider" => "deep_vellum_official_store",
         "source_uri" => "https://example.test/provenance-contract",
         "source_type" => "publisher_dataset",
         "rights_basis" => "field-level fixture provenance"
       }}
    end
  end

  defp empty_hash do
    :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
  end

  defp clear_catalog! do
    [
      SourceLedgerEntry,
      SourceRecord,
      AuditEvent,
      CoverAssignment,
      CoverAsset,
      Identifier,
      Contribution,
      Edition,
      SeriesMembership,
      Series,
      Work,
      Imprint,
      Publisher
    ]
    |> Enum.each(fn resource ->
      Hiraeth.Repo.delete_all(resource)
    end)
  end
end
