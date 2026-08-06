defmodule Hiraeth.Oban.CoverRefreshWorkerTest do
  @moduledoc """
  Tests for the weekly scheduled public cover cache refresh worker.

  Cache writes only ever go to a sandboxed, unique subdirectory under
  priv/static/covers/cache (the only tree the Hiraeth.Covers cache guard
  permits) and are removed on exit. The real cache root itself is never
  targeted by these tests.
  """

  use Hiraeth.DataCase, async: true

  alias Hiraeth.Covers
  alias Hiraeth.Covers.CoverAsset
  alias Hiraeth.Oban.CoverRefreshWorker

  @telemetry_event [:hiraeth, :covers, :scheduled, :refresh]
  @real_cache_root "priv/static/covers/cache"

  setup do
    %{admin: trusted_catalog_actor()}
  end

  test "worker is configured on the covers queue with daily-period refresh-key uniqueness" do
    changeset = CoverRefreshWorker.new(%{})

    assert Ecto.Changeset.fetch_change!(changeset, :queue) == "covers"

    unique = Ecto.Changeset.fetch_change!(changeset, :unique)
    assert unique.keys == [:refresh_key]
    assert unique.period == 86_400
  end

  test "default cache root matches the mix task default" do
    assert CoverRefreshWorker.default_cache_root() == "priv/static/covers/cache"
  end

  test "perform caches an eligible fixture cover into a sandboxed cache root and reports counts",
       %{admin: admin} do
    cache_root = sandboxed_cache_root!("cover-refresh-worker")
    asset = cacheable_asset!(admin)

    # Pre-stage deterministic files at the pipeline's own paths so the real
    # cache_public_covers!/1 adopts them without any network access.
    File.write!(Covers.cache_path(asset, cache_root), jpeg_bytes())
    File.write!(Covers.thumbnail_path(asset, cache_root), jpeg_bytes())

    test_pid = self()
    handler_id = "cover-refresh-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    job = %Oban.Job{
      args: %{"cache_root" => cache_root, "source_urls" => [asset.source_url]}
    }

    assert {:ok, %{cached: 1, skipped: 0, failed: 0}} = CoverRefreshWorker.perform(job)

    reloaded = Ash.get!(CoverAsset, asset.id, authorize?: false)
    assert reloaded.cached_file_path == Covers.cache_path(asset, cache_root)
    assert reloaded.thumbnail_file_path == Covers.thumbnail_path(asset, cache_root)
    assert reloaded.cache_policy == "cache_allowed"
    assert reloaded.cached_at != nil
    assert File.read!(reloaded.cached_file_path) == jpeg_bytes()

    assert_receive {:telemetry, @telemetry_event, measurements, %{status: :ok}}, 1_000
    assert measurements.cached_count == 1
    assert measurements.skipped_count == 0
    assert measurements.failed_count == 0
    assert is_integer(measurements.duration_ms)
  end

  test "perform is non-force: an already cached cover is skipped, not re-fetched", %{
    admin: admin
  } do
    cache_root = sandboxed_cache_root!("cover-refresh-skip")
    asset = cacheable_asset!(admin)

    File.write!(Covers.cache_path(asset, cache_root), jpeg_bytes())
    File.write!(Covers.thumbnail_path(asset, cache_root), jpeg_bytes())

    args = %{"cache_root" => cache_root, "source_urls" => [asset.source_url]}

    assert {:ok, %{cached: 1, skipped: 0, failed: 0}} =
             CoverRefreshWorker.perform(%Oban.Job{args: args})

    assert {:ok, %{cached: 0, skipped: 1, failed: 0}} =
             CoverRefreshWorker.perform(%Oban.Job{args: args})
  end

  test "perform refuses cache roots outside the sandboxed cache tree" do
    outside_root =
      Path.join(System.tmp_dir!(), "cover-refresh-outside-#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/must stay under priv\/static\/covers\/cache/, fn ->
      CoverRefreshWorker.perform(%Oban.Job{args: %{"cache_root" => outside_root}})
    end
  end

  defp sandboxed_cache_root!(prefix) do
    cache_root =
      Path.join(@real_cache_root, "#{prefix}-#{System.unique_integer([:positive])}")

    # Test-side guard: the sandbox root must be a strict subdirectory of the
    # real cache root, never the real cache root itself.
    unless String.starts_with?(Path.expand(cache_root), Path.expand(@real_cache_root) <> "/") do
      raise "test cache root must stay inside a sandboxed subdirectory of #{@real_cache_root}"
    end

    if Path.expand(cache_root) == Path.expand(@real_cache_root) do
      raise "test cache root must never be the real cache root #{@real_cache_root}"
    end

    File.mkdir_p!(cache_root)
    on_exit(fn -> File.rm_rf!(cache_root) end)
    cache_root
  end

  defp cacheable_asset!(admin) do
    CoverAsset
    |> Ash.Changeset.for_create(:create, %{
      source_url:
        "https://covers.example.test/cover-refresh-#{System.unique_integer([:positive])}.jpg",
      provider: "fixture-covers",
      rights_basis: "local_cache_permitted",
      cache_policy: "cache_allowed",
      attribution_text: "Fixture cover provider",
      takedown_state: "visible",
      cached_file_path: nil
    })
    |> Ash.create!(actor: admin)
  end

  defp jpeg_bytes do
    <<0xFF, 0xD8, 0xFF, 0xE0, "fixture-jpeg-raster-bytes", 0xFF, 0xD9>>
  end
end
