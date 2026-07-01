defmodule HiraethWeb.AdminQuarantineLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Hiraeth.Accounts
  alias Hiraeth.Ingestion.{IngestionEvent, ProviderRun, RecordCandidate}
  alias Hiraeth.Oban.{ProviderIngestionWorker, SourceSnapshotReplayWorker}
  alias Hiraeth.Repo
  alias Hiraeth.TestSupport.IngestionFixtures

  require Ash.Query

  defp log_in_admin(conn, role) do
    email = "#{role}-#{System.unique_integer([:positive])}@example.test"
    {:ok, invite} = Accounts.invite_admin(%{email: email, role: role, expires_in: "15m"})
    {:ok, session} = Accounts.consume_invite(invite.raw_token)

    init_test_session(conn, admin_session_token: session.raw_session_token)
  end

  defp candidate!(suffix, attrs \\ %{}) do
    attrs
    |> Map.merge(%{suffix: suffix})
    |> IngestionFixtures.create_candidate!()
  end

  defp update_run!(run, attrs) do
    run
    |> Ash.Changeset.for_update(:record_progress, attrs)
    |> Ash.update!(actor: IngestionFixtures.catalog_writer())
  end

  defp job_for(worker, run_id) do
    worker_name = Oban.Worker.to_string(worker)

    Oban.Job
    |> where([job], job.worker == ^worker_name)
    |> where([job], fragment("?->>? = ?", job.args, "provider_run_id", ^to_string(run_id)))
    |> Repo.one()
  end

  test "admin reviews approve reject and ignore candidates with persisted actor audit", %{
    conn: conn
  } do
    approve =
      candidate!("approve-<script>", %{
        normalized_metadata: %{"title" => "<script>Archive</script>"}
      })

    reject = candidate!("reject", %{diff_classification: "invalid"})
    ignore = candidate!("ignore", %{diff_classification: "removed"})
    conn = log_in_admin(conn, "owner")

    {:ok, view, html} = live(conn, ~p"/admin/ingestion/quarantine/candidates/#{approve.id}")

    assert has_element?(view, "#admin-quarantine-shell")
    assert has_element?(view, "#admin-candidate-link-#{approve.id}")
    assert html =~ "&lt;script&gt;Archive&lt;/script&gt;"

    view
    |> element("#admin-review-form-#{approve.id}")
    |> render_submit(%{
      "review" => %{"reason" => "source diff checked"},
      "review_action" => "approve"
    })

    approved = Ash.get!(RecordCandidate, approve.id, authorize?: false)
    assert approved.review_decision == "approved"
    assert approved.review_actor_email =~ "owner-"
    assert approved.reviewed_at
    assert approved.reviewer_note == "source diff checked"

    {:ok, view, _html} = live(conn, ~p"/admin/ingestion/quarantine/candidates/#{reject.id}")

    view
    |> element("#admin-review-form-#{reject.id}")
    |> render_submit(%{
      "review" => %{"reason" => "not bibliographic"},
      "review_action" => "reject"
    })

    rejected = Ash.get!(RecordCandidate, reject.id, authorize?: false)
    assert rejected.review_decision == "rejected"
    assert rejected.review_actor_email =~ "owner-"

    {:ok, view, _html} = live(conn, ~p"/admin/ingestion/quarantine/candidates/#{ignore.id}")

    view
    |> element("#admin-review-form-#{ignore.id}")
    |> render_submit(%{
      "review" => %{"reason" => "duplicate provider echo"},
      "review_action" => "ignore"
    })

    ignored = Ash.get!(RecordCandidate, ignore.id, authorize?: false)
    assert ignored.review_decision == "ignored"
    assert ignored.review_actor_email =~ "owner-"

    events =
      IngestionEvent
      |> Ash.Query.filter(provider_run_id == ^approve.provider_run_id)
      |> Ash.read!(authorize?: false)

    assert Enum.any?(events, &(&1.event_kind == "candidate:approve"))
  end

  test "empty validation list renders explicit clear state", %{conn: conn} do
    candidate = candidate!("validation-clear", %{validation_errors: []})
    conn = log_in_admin(conn, "admin")

    {:ok, view, _html} = live(conn, ~p"/admin/ingestion/quarantine/candidates/#{candidate.id}")

    assert has_element?(view, "#admin-candidate-validation-#{candidate.id} dd", "clear")
  end

  @tag :destructive_requires_approval
  test "destructive candidate cannot apply without explicit approval", %{conn: conn} do
    candidate = candidate!("destructive", %{diff_classification: "destructive"})
    conn = log_in_admin(conn, "admin")

    {:ok, view, _html} = live(conn, ~p"/admin/ingestion/quarantine/candidates/#{candidate.id}")

    view
    |> element("#admin-review-form-#{candidate.id}")
    |> render_submit(%{
      "review" => %{"reason" => "remove stale public record"},
      "review_action" => "approve"
    })

    blocked = Ash.get!(RecordCandidate, candidate.id, authorize?: false)
    assert blocked.review_decision == "pending_review"
    assert render(view) =~ "Destructive diffs require explicit approval."

    view
    |> element("#admin-review-form-#{candidate.id}")
    |> render_submit(%{
      "review" => %{"reason" => "approved deletion", "approve_destructive" => "true"},
      "review_action" => "approve"
    })

    approved = Ash.get!(RecordCandidate, candidate.id, authorize?: false)
    assert approved.review_decision == "approved"
    assert approved.quarantine_status == "clear"
  end

  test "retry replay cancel and audit export operate on persisted state and jobs", %{conn: conn} do
    source = IngestionFixtures.create_provider_source!("controls")
    failed = IngestionFixtures.create_provider_run!(source, "controls-failed")

    failed =
      update_run!(failed, %{
        status: "failed",
        provenance: %{
          "manifest_path" => "test/fixtures/provider_manifests/valid_api_manifest.json"
        }
      })

    queued = IngestionFixtures.create_provider_run!(source, "controls-queued")
    _snapshot = IngestionFixtures.create_source_snapshot!(source, failed, "controls")
    conn = log_in_admin(conn, "owner")

    {:ok, view, _html} = live(conn, ~p"/admin/ingestion/quarantine/runs/#{failed.id}")

    view |> element("#admin-retry-run-#{failed.id}") |> render_click()
    assert %Oban.Job{} = job_for(ProviderIngestionWorker, failed.id)

    view |> element("#admin-replay-run-#{failed.id}") |> render_click()
    assert %Oban.Job{} = job_for(SourceSnapshotReplayWorker, failed.id)

    render_click(view, "cancel-run", %{"run-id" => queued.id})
    cancelled = Ash.get!(ProviderRun, queued.id, authorize?: false)
    assert cancelled.status == "cancelled"

    export_conn = get(conn, ~p"/admin/ingestion/audit/#{failed.id}/export")
    assert response(export_conn, 200)

    assert get_resp_header(export_conn, "content-disposition") |> List.first() =~
             "hiraeth-audit-#{failed.id}.json"

    payload = Jason.decode!(export_conn.resp_body)
    assert payload["run"]["id"] == failed.id

    assert [%{"storage_ref" => "snapshots/deep-vellum/controls/catalog.json"}] =
             payload["artifacts"]
  end

  test "viewer and malformed controls are denied without crashes", %{conn: conn} do
    candidate = candidate!("viewer-denied")
    conn = log_in_admin(conn, "viewer")

    {:ok, view, _html} = live(conn, ~p"/admin/ingestion/quarantine/candidates/#{candidate.id}")

    render_submit(view, "review-candidate", %{
      "candidate-id" => candidate.id,
      "review" => %{"reason" => "try"},
      "review_action" => "approve"
    })

    unchanged = Ash.get!(RecordCandidate, candidate.id, authorize?: false)
    assert unchanged.review_decision == "pending_review"
    assert render(view) =~ "Only owner or admin operators can use quarantine controls."

    conn = log_in_admin(build_conn(), "admin")
    {:ok, view, _html} = live(conn, ~p"/admin/ingestion/quarantine")

    render_click(view, "retry-run", %{"run-id" => "not-a-run"})
    assert render(view) =~ "Provider run was not found."

    render_submit(view, "review-candidate", %{
      "candidate-id" => "not-a-candidate",
      "review" => %{"reason" => "bad id"},
      "review_action" => "reject"
    })

    assert render(view) =~ "Candidate was not found."
  end

  test "anonymous users are redirected away from quarantine and export", %{conn: conn} do
    candidate = candidate!("anonymous")

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/admin/ingestion/quarantine/candidates/#{candidate.id}")

    export_conn = get(conn, ~p"/admin/ingestion/audit/#{candidate.provider_run_id}/export")
    assert redirected_to(export_conn) == "/"
  end
end
