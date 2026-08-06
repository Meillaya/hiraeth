defmodule Hiraeth.Oban.ProvenanceAuditWorkerTest do
  @moduledoc """
  Tests for the weekly scheduled provenance audit worker.

  The worker is audit-only against live data: it exports evidence to an
  output directory and must never mutate catalog rows (no seeding, no
  database rebuild). Tests write to a tmp output dir and assert catalog
  row counts are unchanged before/after perform/1.
  """

  use Hiraeth.DataCase, async: true

  alias Hiraeth.Oban.ProvenanceAuditWorker
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  @telemetry_event [:hiraeth, :provenance, :scheduled, :audit]

  @catalog_tables ~w(
    works
    editions
    publishers
    contributors
    series
    series_memberships
    contributions
    identifiers
    imprints
    source_records
    source_ledger_entries
    curation_overrides
    cover_assets
    cover_assignments
    import_runs
    audit_events
  )

  setup do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-provenance-audit-#{System.unique_integer([:positive])}/provenance"
      )

    on_exit(fn -> File.rm_rf!(Path.dirname(output_dir)) end)

    %{admin: trusted_catalog_actor(), output_dir: output_dir}
  end

  test "worker is configured on the audit queue with daily-period audit-key uniqueness" do
    changeset = ProvenanceAuditWorker.new(%{})

    assert Ecto.Changeset.fetch_change!(changeset, :queue) == "audit"

    unique = Ecto.Changeset.fetch_change!(changeset, :unique)
    assert unique.keys == [:audit_key]
    assert unique.period == 86_400
  end

  test "default output dir matches the mix task default" do
    assert ProvenanceAuditWorker.default_output_dir() == "artifacts/qa/provenance"
  end

  test "perform audits seeded live data into a tmp dir without changing catalog row counts", %{
    admin: admin,
    output_dir: output_dir
  } do
    record = seed_provenance_fixture!(admin)
    counts_before = catalog_row_counts()

    assert {:ok, summary} =
             ProvenanceAuditWorker.perform(%Oban.Job{args: %{"output_dir" => output_dir}})

    assert summary.source_ledger_rows >= 1
    assert summary.invalid_public_covers >= 0
    assert summary.output_dir == output_dir

    for file <-
          ~w(source-ledger.csv takedown-audit.csv cover-cache-audit.csv audit-provenance.json) do
      assert File.exists?(Path.join(output_dir, file)), "expected #{file} in #{output_dir}"
    end

    ledger_csv = File.read!(Path.join(output_dir, "source-ledger.csv"))
    assert ledger_csv =~ record.source_uri

    # Audit-only guarantee: the scheduled audit never mutates live catalog rows.
    assert catalog_row_counts() == counts_before
  end

  test "perform emits one scheduled-audit telemetry event", %{
    admin: admin,
    output_dir: output_dir
  } do
    seed_provenance_fixture!(admin)

    test_pid = self()
    handler_id = "provenance-audit-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _summary} =
             ProvenanceAuditWorker.perform(%Oban.Job{args: %{"output_dir" => output_dir}})

    assert_receive {:telemetry, @telemetry_event, measurements, %{status: :ok}}, 1_000
    assert measurements.source_ledger_rows >= 1
    assert is_integer(measurements.invalid_public_cover_count)
    assert is_integer(measurements.duration_ms)
  end

  defp seed_provenance_fixture!(admin) do
    suffix = System.unique_integer([:positive])

    record =
      SourceRecord
      |> Ash.Changeset.for_create(:create, %{
        provider: "fixture-audit",
        source_type: "api",
        source_uri: "fixture:audit:edition:weekly-audit-#{suffix}",
        file_checksum: "sha256:task17auditfixture#{suffix}",
        license_note: "Publisher permission for scheduled audit fixture",
        raw_payload: %{
          "displayed_fields" => ["title"],
          "title" => "Weekly Audit Fixture",
          "field_sources" => %{
            "title" => %{
              "source_uri" => "fixture:audit:edition:weekly-audit-#{suffix}",
              "provider" => "fixture-audit",
              "source_type" => "api",
              "rights_basis" => "publisher_permission"
            }
          }
        },
        imported_at: DateTime.utc_now(:second)
      })
      |> Ash.create!(actor: admin)

    SourceLedgerEntry
    |> Ash.Changeset.for_create(:create, %{
      event_type: "imported",
      message: "fixture ledger entry for scheduled audit test",
      occurred_at: DateTime.utc_now(:second),
      source_record_id: record.id
    })
    |> Ash.create!(actor: admin)

    record
  end

  defp catalog_row_counts do
    Map.new(@catalog_tables, fn table ->
      {:ok, %{rows: [[count]]}} = Hiraeth.Repo.query("select count(*) from #{table}", [])
      {table, count}
    end)
  end
end
