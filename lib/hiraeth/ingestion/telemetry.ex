defmodule Hiraeth.Ingestion.Telemetry do
  @moduledoc """
  Lightweight telemetry hooks for operated ingestion runs.

  Events intentionally carry identifiers, phase names, statuses, counts, and
  coarse error codes only. They must not include raw provider payloads, source
  records, URLs, credentials, or sidecar response bodies.
  """

  @phase_event [:hiraeth, :ingestion, :phase, :stop]
  @scheduler_tick_event [:hiraeth, :ingestion, :scheduler, :tick]
  @sidecar_error_event [:hiraeth, :ingestion, :sidecar, :error]
  @queue_latency_event [:hiraeth, :ingestion, :queue, :latency]
  @cover_cache_event [:hiraeth, :ingestion, :cover, :cache]

  def phase_event, do: @phase_event
  def scheduler_tick_event, do: @scheduler_tick_event
  def sidecar_error_event, do: @sidecar_error_event
  def queue_latency_event, do: @queue_latency_event
  def cover_cache_event, do: @cover_cache_event

  def phase_stop(run, phase, status, attrs) do
    measurements = %{
      source_count: count(attrs, :source_count),
      snapshot_count: count(attrs, :snapshot_count),
      candidate_count: count(attrs, :candidate_count),
      accepted_count: count(attrs, :accepted_count),
      rejected_count: count(attrs, :rejected_count),
      error_count: count(attrs, :error_count),
      quarantine_age_seconds: count(attrs, :quarantine_age_seconds)
    }

    metadata = %{
      provider_run_id: run.id,
      provider_source_id: run.provider_source_id,
      phase: phase,
      status: status,
      error_code: error_code(attrs)
    }

    :telemetry.execute(@phase_event, measurements, metadata)
  end

  def scheduler_tick(summary, measurements \\ %{}, metadata \\ %{}) do
    measurements =
      Map.merge(
        %{
          created_count: summary_count(summary, :created),
          skipped_count: summary_count(summary, :skipped)
        },
        measurements
      )

    :telemetry.execute(
      @scheduler_tick_event,
      measurements,
      sanitize_metadata(metadata, [:tick_at])
    )
  end

  def sidecar_error(operation, code, metadata \\ %{}) do
    metadata =
      metadata
      |> sanitize_metadata([:provider, :provider_run_id, :provider_source_id])
      |> Map.merge(%{operation: operation, error_code: code})

    :telemetry.execute(@sidecar_error_event, %{count: 1}, metadata)
  end

  def queue_latency(worker, inserted_at, metadata \\ %{}) do
    duration = queue_latency_ms(inserted_at)

    metadata =
      metadata
      |> sanitize_metadata([:provider, :provider_run_id, :provider_source_id])
      |> Map.put(:worker, worker)

    :telemetry.execute(@queue_latency_event, %{duration: duration}, metadata)
  end

  def cover_cache(status, counts, metadata \\ %{}) do
    measurements = %{
      candidate_count: count(counts, :candidate_count),
      cached_count: count(counts, :cached_count),
      failed_count: count(counts, :failed_count),
      error_count: count(counts, :error_count)
    }

    metadata =
      metadata
      |> sanitize_metadata([:provider, :provider_run_id, :provider_source_id])
      |> Map.put(:status, status)

    :telemetry.execute(@cover_cache_event, measurements, metadata)
  end

  defp sanitize_metadata(metadata, allowed_keys) when is_map(metadata) do
    Map.new(allowed_keys, fn key -> {key, metadata_value(metadata, key)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or not safe_metadata_value?(value) end)
    |> Map.new()
  end

  defp sanitize_metadata(_metadata, _allowed_keys), do: %{}

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp safe_metadata_value?(value) when is_binary(value), do: byte_size(value) <= 256
  defp safe_metadata_value?(value) when is_atom(value), do: true
  defp safe_metadata_value?(value) when is_integer(value), do: true
  defp safe_metadata_value?(%DateTime{}), do: true
  defp safe_metadata_value?(_value), do: false

  defp queue_latency_ms(%DateTime{} = inserted_at) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :millisecond)
    |> max(0)
  end

  defp queue_latency_ms(%NaiveDateTime{} = inserted_at) do
    inserted_at
    |> DateTime.from_naive!("Etc/UTC")
    |> queue_latency_ms()
  end

  defp queue_latency_ms(_inserted_at), do: 0

  defp summary_count(summary, key) when is_map(summary) do
    summary
    |> Map.get(key, [])
    |> length()
  end

  defp count(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key), 0)) do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp error_code(attrs) when is_map(attrs) do
    case Map.get(attrs, :error) || Map.get(attrs, "error") do
      %{code: code} -> code
      %{"code" => code} -> code
      _error -> nil
    end
  end
end
