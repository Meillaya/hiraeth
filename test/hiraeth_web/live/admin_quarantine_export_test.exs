defmodule HiraethWeb.AdminQuarantineExportTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Hiraeth.Accounts
  alias Hiraeth.Ingestion.{IngestionEvent, RecordCandidate}
  alias Hiraeth.TestSupport.IngestionFixtures

  defp log_in_admin(conn, role) do
    email = "#{role}-#{System.unique_integer([:positive])}@example.test"
    {:ok, invite} = Accounts.invite_admin(%{email: email, role: role, expires_in: "15m"})
    {:ok, session} = Accounts.consume_invite(invite.raw_token)

    init_test_session(conn, admin_session_token: session.raw_session_token)
  end

  defp candidate_on_run!(run, snapshot, suffix) do
    attrs =
      suffix
      |> IngestionFixtures.candidate_attrs()
      |> Map.merge(%{provider_run_id: run.id, source_snapshot_id: snapshot.id})

    RecordCandidate
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  defp event_for_candidate!(source, run, candidate, index) do
    IngestionEvent
    |> Ash.Changeset.for_create(:create, %{
      provider_run_id: run.id,
      provider_source_id: source.id,
      source_snapshot_id: candidate.source_snapshot_id,
      event_kind: "candidate:export:#{index}",
      status: "succeeded",
      message: "export fixture #{index}",
      payload: %{candidate_id: candidate.id},
      occurred_at: DateTime.add(~U[2026-06-01 12:00:00Z], index, :second)
    })
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  test "viewer admins cannot export quarantine audit data", %{conn: conn} do
    candidate = IngestionFixtures.create_candidate!(%{suffix: "viewer-export-denied"})
    conn = log_in_admin(conn, "viewer")

    {:ok, view, _html} =
      live(conn, ~p"/admin/ingestion/quarantine/runs/#{candidate.provider_run_id}")

    refute has_element?(view, "a#admin-export-run-#{candidate.provider_run_id}")
    assert has_element?(view, "#admin-export-locked-run-#{candidate.provider_run_id}")

    export_conn = get(conn, ~p"/admin/ingestion/audit/#{candidate.provider_run_id}/export")

    assert redirected_to(export_conn) == ~p"/admin/ingestion/quarantine"
    assert Phoenix.Flash.get(export_conn.assigns.flash, :error) =~ "owner or admin"
  end

  test "audit export pages complete run-scoped candidates events and artifacts", %{conn: conn} do
    source = IngestionFixtures.create_provider_source!("complete-export")
    run = IngestionFixtures.create_provider_run!(source, "complete-export")
    snapshot = IngestionFixtures.create_source_snapshot!(source, run, "complete-export")

    candidates =
      for index <- 1..80 do
        candidate_on_run!(run, snapshot, "complete-export-#{index}")
      end

    candidates
    |> Enum.take(3)
    |> Enum.with_index(1)
    |> Enum.each(fn {candidate, index} -> event_for_candidate!(source, run, candidate, index) end)

    conn = log_in_admin(conn, "admin")
    export_conn = get(conn, ~p"/admin/ingestion/audit/#{run.id}/export")

    assert response(export_conn, 200)
    payload = Jason.decode!(export_conn.resp_body)

    assert payload["run"]["id"] == run.id
    assert length(payload["candidates"]) == 80
    assert length(payload["events"]) == 3

    assert [%{"storage_ref" => "snapshots/deep-vellum/complete-export/catalog.json"}] =
             payload["artifacts"]

    assert payload["metadata"]["complete?"] == true
    assert payload["metadata"]["truncated?"] == false
    assert payload["metadata"]["warnings"] == []
    assert payload["metadata"]["page_size"] == 50

    assert payload["metadata"]["row_counts"] == %{
             "artifacts" => 1,
             "candidates" => 80,
             "events" => 3
           }

    assert payload["metadata"]["filters"]["provider_run_id"] == run.id

    assert Enum.sort(payload["metadata"]["filters"]["candidate_ids"]) ==
             Enum.sort(Enum.map(candidates, & &1.id))

    refute Enum.any?(payload["artifacts"], &String.contains?(&1["storage_ref"], ".."))
  end

  test "malformed export id redirects without crashing", %{conn: conn} do
    conn = log_in_admin(conn, "owner")
    export_conn = get(conn, ~p"/admin/ingestion/audit/not-a-run/export")

    assert redirected_to(export_conn) == ~p"/admin/ingestion/quarantine"
    assert Phoenix.Flash.get(export_conn.assigns.flash, :error) =~ "not found"
  end
end
