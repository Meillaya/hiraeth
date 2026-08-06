defmodule Hiraeth.Oban.CoverRefreshWorker do
  @moduledoc """
  Oban worker for the weekly scheduled public cover cache refresh.

  Runs on the `:covers` queue every Sunday at 04:00 (see the Oban crontab
  in config/config.exs). perform/1 calls `Hiraeth.Covers.cache_public_covers!/1`
  directly with the same default (non-force, non-strict) options as
  `mix hiraeth.cache_covers` — it never shells out to Mix.

  The job args may carry two optional overrides, both JSON-safe:

    * `"cache_root"` — an alternate cache root under priv/static/covers/cache
      (the `--cache-root` equivalent; the Hiraeth.Covers sandbox guard
      rejects anything outside that tree)
    * `"source_urls"` — restrict the refresh to specific cover source URLs

  Cron inserts the job with empty args, so production runs use exactly the
  mix task defaults. Force/strict behavior is deliberately never available
  from this worker.
  """

  use Oban.Worker,
    queue: :covers,
    unique: [
      keys: [:refresh_key],
      period: 86_400
    ]

  @default_cache_root "priv/static/covers/cache"
  @scheduled_refresh_event [:hiraeth, :covers, :scheduled, :refresh]

  def default_cache_root, do: @default_cache_root

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args = args || %{}
    started_at = System.monotonic_time(:millisecond)
    summary = Hiraeth.Covers.cache_public_covers!(cover_options(args))
    duration_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      @scheduled_refresh_event,
      %{
        cached_count: summary.cached,
        skipped_count: summary.skipped,
        failed_count: summary.failed,
        duration_ms: duration_ms
      },
      %{status: :ok, worker: :cover_refresh_worker}
    )

    {:ok, %{cached: summary.cached, skipped: summary.skipped, failed: summary.failed}}
  end

  defp cover_options(args) do
    [
      force?: false,
      cache_root: Map.get(args, "cache_root", @default_cache_root),
      strict?: false,
      timeout: 15_000,
      max_concurrency: 4
    ]
    |> put_source_urls(args)
  end

  defp put_source_urls(opts, %{"source_urls" => source_urls}) when is_list(source_urls) do
    Keyword.put(opts, :source_urls, source_urls)
  end

  defp put_source_urls(opts, _args), do: opts
end
