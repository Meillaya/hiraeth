defmodule Hiraeth.Ingestion.CoverCandidateTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Covers.CoverAsset
  alias Hiraeth.Ingestion.{CoverPipeline, IngestionEvent, RecordCandidate}
  alias Hiraeth.TestSupport.IngestionFixtures

  require Ash.Query

  @tag :rejects_unallowed_host
  test "rejects unallowed host as a quarantined cover candidate without exposing a remote public URL" do
    candidate =
      IngestionFixtures.create_candidate!(%{
        suffix: unique_suffix("bad-host"),
        candidate_identity: "deep-vellum:bad-host:cover",
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

    assert [%{record_candidate_id: candidate_id, retry_state: "quarantined", reason: reason}] =
             summary.failures

    assert candidate_id == candidate.id
    assert reason =~ "allowlisted"

    reloaded = Ash.get!(RecordCandidate, candidate.id, authorize?: false)
    assert reloaded.review_status == "quarantined"
    assert reloaded.quarantine_status == "quarantined"
    assert reloaded.review_decision == "pending_review"
    assert Enum.any?(reloaded.validation_errors, &String.contains?(&1, "allowlisted"))

    assert %{"cover_cache" => %{"status" => "quarantined", "retry_state" => "quarantined"}} =
             reloaded.normalized_metadata

    refute Map.has_key?(reloaded.normalized_metadata, "public_url")

    assert [] =
             CoverAsset
             |> Ash.Query.filter(source_url == "https://evil.example.test/cover.jpg")
             |> Ash.read!(authorize?: false)

    refute Map.has_key?(reloaded.normalized_metadata["cover_cache"], "public_url")
    assert [] = cover_events(candidate, "succeeded")

    assert [%IngestionEvent{status: "failed", source_snapshot_id: source_snapshot_id}] =
             cover_events(candidate, "failed")

    assert source_snapshot_id == candidate.source_snapshot_id
  end

  test "one failed cover quarantines only that candidate while successful candidates keep cached provenance" do
    ok_url = "https://covers.example.test/ok-candidate.jpg"
    fail_url = "https://covers.example.test/fail-candidate.jpg"

    ok_candidate =
      IngestionFixtures.create_candidate!(%{
        suffix: unique_suffix("ok"),
        candidate_identity: "fixture-covers:ok:cover",
        record_type: "cover",
        source_uri: ok_url,
        raw_metadata: cover_metadata(ok_url, "fixture-covers"),
        normalized_metadata: cover_metadata(ok_url, "fixture-covers")
      })

    failed_candidate =
      IngestionFixtures.create_candidate!(%{
        suffix: unique_suffix("fail"),
        candidate_identity: "fixture-covers:fail:cover",
        record_type: "cover",
        source_uri: fail_url,
        raw_metadata: cover_metadata(fail_url, "fixture-covers"),
        normalized_metadata: cover_metadata(fail_url, "fixture-covers")
      })

    cache_root = unique_cache_root("candidate-level")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    plug = fn conn ->
      if conn.request_path == "/fail-candidate.jpg" do
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.resp(500, "server error")
      else
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.resp(200, jpeg_bytes())
      end
    end

    assert {:ok, summary} =
             CoverPipeline.cache_cover_candidates!([ok_candidate, failed_candidate], %{
               cache_root: cache_root,
               max_concurrency: 2,
               req_options: [plug: plug, retry: false],
               thumbnailer: thumbnailer()
             })

    assert %{cached: 1, failed: 1, quarantined: 1} = summary

    ok_reloaded = Ash.get!(RecordCandidate, ok_candidate.id, authorize?: false)
    failed_reloaded = Ash.get!(RecordCandidate, failed_candidate.id, authorize?: false)

    assert ok_reloaded.review_status == "accepted"
    assert ok_reloaded.quarantine_status == "clear"
    assert ok_reloaded.review_decision == "approved"

    assert %{
             "cached_file_path" => cached_file_path,
             "thumbnail_file_path" => thumbnail_file_path,
             "source_snapshot_id" => source_snapshot_id,
             "record_candidate_id" => record_candidate_id,
             "status" => "cached"
           } = ok_reloaded.normalized_metadata["cover_cache"]

    assert source_snapshot_id == ok_candidate.source_snapshot_id
    assert record_candidate_id == ok_candidate.id
    assert String.starts_with?(cached_file_path, cache_root)
    assert File.read!(cached_file_path) == jpeg_bytes()
    assert File.read!(thumbnail_file_path) == "fake thumbnail bytes"

    assert failed_reloaded.review_status == "quarantined"
    assert failed_reloaded.quarantine_status == "quarantined"
    assert failed_reloaded.normalized_metadata["cover_cache"]["retry_state"] == "retryable"
    refute File.exists?(cache_path(fail_url, cache_root))
    assert File.exists?(cached_file_path)

    assert [%IngestionEvent{status: "succeeded"}] = cover_events(ok_candidate, "succeeded")
    assert [%IngestionEvent{status: "failed"}] = cover_events(failed_candidate, "failed")
  end

  test "rejects unsafe cache_root before creating external directories or files" do
    source_url = "https://covers.example.test/external-root.jpg"

    candidate =
      IngestionFixtures.create_candidate!(%{
        suffix: unique_suffix("external-root"),
        candidate_identity: "fixture-covers:external-root:cover",
        record_type: "cover",
        source_uri: source_url,
        raw_metadata: cover_metadata(source_url, "fixture-covers"),
        normalized_metadata: cover_metadata(source_url, "fixture-covers")
      })

    external_root =
      Path.join(System.tmp_dir!(), "hiraeth-cover-external-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(external_root) end)

    assert {:error, failures} =
             CoverPipeline.cache_cover_candidates!([candidate], %{
               cache_root: external_root,
               max_concurrency: 1,
               req_options: [plug: unexpected_fetch_plug(), retry: false],
               thumbnailer: thumbnailer()
             })

    assert [%{reason: reason}] = failures
    assert reason =~ "canonical cover cache root"
    refute File.exists?(external_root)

    reloaded = Ash.get!(RecordCandidate, candidate.id, authorize?: false)
    refute Map.has_key?(reloaded.normalized_metadata, "cover_cache")
  end

  test "strict policy keeps all-or-nothing behavior for candidate cover caching" do
    ok_url = "https://covers.example.test/strict-ok.jpg"
    fail_url = "https://covers.example.test/strict-fail.jpg"

    ok_candidate =
      IngestionFixtures.create_candidate!(%{
        suffix: unique_suffix("strict-ok"),
        candidate_identity: "fixture-covers:strict-ok:cover",
        record_type: "cover",
        source_uri: ok_url,
        raw_metadata: cover_metadata(ok_url, "fixture-covers"),
        normalized_metadata: cover_metadata(ok_url, "fixture-covers")
      })

    failed_candidate =
      IngestionFixtures.create_candidate!(%{
        suffix: unique_suffix("strict-fail"),
        candidate_identity: "fixture-covers:strict-fail:cover",
        record_type: "cover",
        source_uri: fail_url,
        raw_metadata: cover_metadata(fail_url, "fixture-covers"),
        normalized_metadata: cover_metadata(fail_url, "fixture-covers")
      })

    cache_root = unique_cache_root("candidate-strict")
    on_exit(fn -> File.rm_rf!(cache_root) end)

    plug = fn conn ->
      if conn.request_path == "/strict-fail.jpg" do
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.resp(500, "server error")
      else
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.resp(200, jpeg_bytes())
      end
    end

    assert {:error, failures} =
             CoverPipeline.cache_cover_candidates!([ok_candidate, failed_candidate], %{
               cache_root: cache_root,
               max_concurrency: 2,
               strict?: true,
               req_options: [plug: plug, retry: false],
               thumbnailer: thumbnailer()
             })

    assert [%{record_candidate_id: failed_candidate_id}] = failures
    assert failed_candidate_id == failed_candidate.id
    refute File.exists?(cache_path(ok_url, cache_root))
    refute File.exists?(thumbnail_path(ok_url, cache_root))
  end

  defp cover_metadata(source_url, provider \\ "deep_vellum_official_store") do
    %{
      "source_url" => source_url,
      "provider" => provider,
      "rights_basis" => "local_cache_permitted",
      "cache_policy" => "cache_allowed",
      "attribution_text" => "Fixture cover",
      "allowed_cover_hosts" => ["covers.example.test"]
    }
  end

  defp cover_events(candidate, status) do
    IngestionEvent
    |> Ash.Query.filter(
      provider_run_id == ^candidate.provider_run_id and
        event_kind == "cover_cache_candidate" and status == ^status
    )
    |> Ash.read!(authorize?: false)
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

  defp unique_suffix(label) do
    "#{label}-#{System.unique_integer([:positive])}"
  end

  defp unique_cache_root(label) do
    Path.expand(
      Path.join("priv/static/covers/cache", "#{label}-#{System.unique_integer([:positive])}")
    )
  end

  defp cache_path(source_url, cache_root) do
    Path.join(cache_root, "#{sha256(source_url)}#{Path.extname(URI.parse(source_url).path)}")
  end

  defp thumbnail_path(source_url, cache_root) do
    Path.join(cache_root, "#{sha256(source_url)}-thumb.jpg")
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp jpeg_bytes do
    <<0xFF, 0xD8, 0xFF, 0xE0, "fixture-jpeg-raster-bytes", 0xFF, 0xD9>>
  end
end
