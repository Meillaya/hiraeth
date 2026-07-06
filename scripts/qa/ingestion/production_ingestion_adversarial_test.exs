defmodule HiraethQA.ProductionIngestionAdversarialTest do
  use Hiraeth.DataCase, async: false
  use HiraethWeb, :verified_routes

  import Phoenix.ConnTest
  import Plug.Conn
  import Hiraeth.TestSupport.ApplyPhaseRegressionHelpers

  alias Hiraeth.Covers.CoverAsset
  alias Hiraeth.Ingestion.{CoverPipeline, ProviderRun, ProviderScheduler, RecordCandidate}
  alias Hiraeth.Ingestion.Phases.ApplyCandidates
  alias Hiraeth.TestSupport.IngestionFixtures

  require Ash.Query

  @endpoint HiraethWeb.Endpoint
  @safe_error_denylists [
    "Traceback",
    "Stacktrace",
    "** (",
    "SECRET",
    "TOKEN",
    "COOKIE",
    "password="
  ]
  @tick_at ~U[2026-06-29 12:00:00Z]

  @tag :destructive_diff
  test "destructive diff is quarantined and fails closed during apply" do
    %{run: run, snapshot: snapshot, manifest: manifest} = setup_context("t25-destructive")

    destructive =
      create_candidate!(run, snapshot, "t25-destructive", %{
        diff_classification: "destructive",
        review_status: "accepted",
        quarantine_status: "clear",
        review_decision: "approved"
      })

    assert destructive.review_status == "quarantined"
    assert destructive.quarantine_status == "quarantined"
    assert destructive.review_decision == "pending_review"

    assert {:ok, applied_context} = ApplyCandidates.run(context(run, manifest))
    assert applied_context.applied_candidates == []
    assert [%{id: blocked_id}] = applied_context.blocked_candidates
    assert blocked_id == destructive.id
    assert applied_context.apply_summary.source_count == 0

    IO.puts(
      "PASS destructive diff quarantined/fails closed candidate_id=#{destructive.id} applied_count=0 blocked_count=1"
    )
  end

  @tag :cover_host_rejection
  test "cover host rejection blocks unsafe host without unsafe error disclosure" do
    candidate =
      IngestionFixtures.create_candidate!(%{
        suffix: "t25-bad-cover-#{System.unique_integer([:positive])}",
        candidate_identity: "deep-vellum:t25:bad-cover",
        record_type: "cover",
        source_uri: "https://evil.example.test/cover.jpg",
        raw_metadata: cover_metadata("https://evil.example.test/cover.jpg"),
        normalized_metadata: cover_metadata("https://evil.example.test/cover.jpg")
      })

    assert {:ok, summary} =
             CoverPipeline.cache_cover_candidates!([candidate], %{
               max_concurrency: 1,
               req_options: [plug: unexpected_fetch_plug()],
               thumbnailer: thumbnailer()
             })

    assert %{cached: 0, failed: 1, quarantined: 1} = summary
    assert [%{reason: reason}] = summary.failures
    assert reason =~ "allowlisted"
    assert_safe_error!(reason)

    reloaded = Ash.get!(RecordCandidate, candidate.id, authorize?: false)
    assert reloaded.review_status == "quarantined"
    assert reloaded.quarantine_status == "quarantined"
    refute Map.has_key?(reloaded.normalized_metadata, "public_url")
    refute Map.has_key?(reloaded.normalized_metadata["cover_cache"], "public_url")

    assert [] =
             CoverAsset
             |> Ash.Query.filter(source_url == "https://evil.example.test/cover.jpg")
             |> Ash.read!(authorize?: false)

    IO.puts(
      "PASS cover host rejection blocked unsafe host quarantined=1 cached=0 safe_error=#{inspect(reason)}"
    )
  end

  @tag :scheduler_duplicate_prevention
  test "scheduler duplicate prevention prevents duplicate active runs" do
    source = create_scheduler_source!("t25-duplicate-#{System.unique_integer([:positive])}")
    opts = [now: @tick_at, provider_source_ids: [source.id]]

    assert {:ok, %{created: [_run], skipped: []}} = ProviderScheduler.schedule_tick(opts)
    assert {:ok, %{created: [], skipped: [skip]}} = ProviderScheduler.schedule_tick(opts)
    assert skip.reason == :active_run_exists

    active_runs = active_runs_for(source)
    assert length(active_runs) == 1

    IO.puts(
      "PASS scheduler duplicate prevention created=1 duplicate_skipped=1 active_runs=#{length(active_runs)} reason=#{skip.reason}"
    )
  end

  @tag :admin_unauthorized_access
  test "admin unauthorized access fails closed without exposing admin data" do
    conn = get(build_conn(), ~p"/admin/ingestion")
    location = List.first(get_resp_header(conn, "location"))
    body = conn.resp_body || ""

    assert conn.status in [302, 401, 403]
    assert location == "/"
    refute body =~ "Provider registry and run timeline"
    refute body =~ "admin@example"
    assert_safe_error!(body)

    IO.puts(
      "PASS admin unauthorized access failed closed status=#{conn.status} location=#{location} admin_data_exposed=false"
    )
  end

  defp create_scheduler_source!(suffix) do
    IngestionFixtures.create_provider_source!(suffix)
    |> Ash.Changeset.for_update(:update, %{ingestion_mode: "manifest", enabled?: true})
    |> Ash.update!(actor: IngestionFixtures.catalog_writer())
  end

  defp active_runs_for(source) do
    ProviderRun
    |> Ash.Query.filter(provider_source_id == ^source.id and status in ["queued", "running"])
    |> Ash.read!(authorize?: false)
  end

  defp cover_metadata(source_url) do
    %{
      "source_url" => source_url,
      "provider" => "deep_vellum_official_store",
      "rights_basis" => "local_cache_permitted",
      "cache_policy" => "cache_allowed",
      "attribution_text" => "Fixture cover",
      "allowed_cover_hosts" => ["covers.example.test"]
    }
  end

  defp unexpected_fetch_plug do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.resp(200, jpeg_bytes())
    end
  end

  defp thumbnailer do
    fn _source_path, thumbnail_path ->
      File.write!(thumbnail_path, "fake thumbnail bytes")
      {:ok, thumbnail_path}
    end
  end

  defp jpeg_bytes do
    <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0xFF, 0xD9>>
  end

  defp assert_safe_error!(text) when is_binary(text) do
    refute Enum.any?(@safe_error_denylists, &String.contains?(text, &1))
  end
end
