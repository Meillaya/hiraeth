defmodule HiraethWeb.AdminIngestionLiveTest do
  use HiraethWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hiraeth.Accounts
  alias Hiraeth.Ingestion.{IngestionEvent, ProviderSource}
  alias HiraethWeb.Admin.IngestionRegistry
  alias Hiraeth.TestSupport.IngestionFixtures

  defp log_in_admin(conn, role) do
    email = "#{role}-#{System.unique_integer([:positive])}@example.test"
    {:ok, invite} = Accounts.invite_admin(%{email: email, role: role, expires_in: "15m"})
    {:ok, session} = Accounts.consume_invite(invite.raw_token)

    init_test_session(conn, admin_session_token: session.raw_session_token)
  end

  defp capture_repo_queries(fun) do
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:hiraeth, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(owner, {:repo_query, metadata.query})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler_id)
    {result, drain_repo_queries([])}
  end

  defp drain_repo_queries(queries) do
    receive do
      {:repo_query, query} -> drain_repo_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp queries_for_table(queries, table) do
    Enum.filter(queries, &(String.downcase(&1) =~ ~s(from "#{table}")))
  end

  defp query_contains?(queries, table, fragments) do
    queries
    |> queries_for_table(table)
    |> Enum.any?(fn query ->
      normalized = String.downcase(query)
      Enum.all?(fragments, &(normalized =~ String.downcase(&1)))
    end)
  end

  defp seeded_registry!(suffix) do
    source = IngestionFixtures.create_provider_source!(suffix)
    run = IngestionFixtures.create_provider_run!(source, suffix)
    snapshot = IngestionFixtures.create_source_snapshot!(source, run, suffix)

    event =
      IngestionEvent
      |> Ash.Changeset.for_create(:create, %{
        provider_run_id: run.id,
        provider_source_id: source.id,
        source_snapshot_id: snapshot.id,
        event_kind: "phase:fetch_snapshot",
        status: "succeeded",
        message: "Fetched <img src=x> safely as text",
        payload: %{"phase" => "fetch_snapshot"},
        occurred_at: ~U[2026-06-01 12:05:00Z]
      })
      |> Ash.create!(actor: IngestionFixtures.catalog_writer())

    %{source: source, run: run, snapshot: snapshot, event: event}
  end

  test "registry loads provider timeline with bounded query-filtered reads" do
    %{source: source, run: run} = seeded_registry!("bounded-primary")
    %{run: other_run} = seeded_registry!("bounded-other")

    {state, queries} =
      capture_repo_queries(fn -> IngestionRegistry.load(%{"id" => to_string(source.id)}) end)

    assert Enum.map(state.provider_runs, & &1.id) == [run.id]
    refute Enum.any?(state.provider_runs, &(&1.id == other_run.id))

    assert query_contains?(queries, "provider_sources", ["limit"])
    assert query_contains?(queries, "provider_runs", ["provider_source_id", "limit"])
    assert query_contains?(queries, "ingestion_events", ["provider_run_id", "limit"])
    assert query_contains?(queries, "source_snapshots", ["provider_run_id", "limit"])
  end

  test "admin lists providers, views timeline, artifacts, and can pause then resume schedule", %{
    conn: conn
  } do
    %{source: source, run: run, snapshot: snapshot, event: event} = seeded_registry!("admin-ui")
    conn = log_in_admin(conn, "owner")

    {:ok, view, _html} = live(conn, ~p"/admin/ingestion")

    assert has_element?(view, "#admin-ingestion-shell")
    assert has_element?(view, "#admin-provider-registry")
    assert has_element?(view, "#admin-provider-link-#{source.id}", source.provider_name)
    assert has_element?(view, "#admin-run-timeline")
    assert has_element?(view, "#admin-run-title-#{run.id}", run.run_key)
    assert has_element?(view, "#admin-phase-fetch-snapshot", "fetch_snapshot")
    assert has_element?(view, "#admin-event-#{event.id}", "Fetched <img src=x> safely as text")
    assert has_element?(view, "#admin-artifact-link-#{snapshot.id}", snapshot.storage_ref)

    artifact_href =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#admin-artifact-link-#{snapshot.id}")
      |> LazyHTML.attribute("href")

    assert artifact_href == [~p"/admin/ingestion/artifacts/#{snapshot.id}"]
    refute artifact_href == ["#admin-artifact-#{snapshot.id}"]

    view
    |> element("#admin-artifact-link-#{snapshot.id}")
    |> render_click()

    assert_patch(view, ~p"/admin/ingestion/artifacts/#{snapshot.id}")
    assert has_element?(view, "#admin-artifact-detail", snapshot.storage_ref)

    view
    |> element("#admin-pause-provider-#{source.id}")
    |> render_click()

    paused = Ash.get!(ProviderSource, source.id, authorize?: false)
    refute paused.enabled?
    assert has_element?(view, "#admin-resume-provider-#{source.id}")

    view
    |> element("#admin-resume-provider-#{source.id}")
    |> render_click()

    resumed = Ash.get!(ProviderSource, source.id, authorize?: false)
    assert resumed.enabled?
    assert has_element?(view, "#admin-pause-provider-#{source.id}")
  end

  @tag :unauthorized_cannot_pause
  test "viewer can open registry but cannot pause provider schedules", %{conn: conn} do
    %{source: source} = seeded_registry!("viewer-denied")
    conn = log_in_admin(conn, "viewer")

    {:ok, view, _html} = live(conn, ~p"/admin/ingestion")
    assert has_element?(view, "#admin-provider-link-#{source.id}", source.provider_name)

    view
    |> element("#admin-pause-provider-#{source.id}")
    |> render_click()

    reloaded = Ash.get!(ProviderSource, source.id, authorize?: false)
    assert reloaded.enabled?
    assert render(view) =~ "Only owner or admin operators can pause or resume schedules."
  end

  test "malformed provider id does not crash pause handler", %{conn: conn} do
    %{source: source} = seeded_registry!("malformed-id")
    conn = log_in_admin(conn, "admin")

    {:ok, view, _html} = live(conn, ~p"/admin/ingestion")

    render_click(view, "pause-provider", %{"provider-id" => "not-a-provider-id"})

    assert render(view) =~ "Provider source was not found."

    render_click(view, "not-a-provider-action", %{"provider-id" => source.id})

    assert has_element?(view, "#admin-provider-registry")
  end

  test "anonymous users are redirected away from admin ingestion", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/ingestion")
  end
end
