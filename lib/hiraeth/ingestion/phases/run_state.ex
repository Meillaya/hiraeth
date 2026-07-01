defmodule Hiraeth.Ingestion.Phases.RunState do
  @moduledoc false

  alias Hiraeth.Ingestion.{IngestionEvent, ProviderRun, ProviderSource, Telemetry}

  @catalog_writer %{id: "ingestion-phase-worker", catalog_write?: true}

  require Ash.Query

  def catalog_writer, do: @catalog_writer

  def ensure_source_and_run!(manifest, opts \\ []) do
    source = ensure_provider_source!(manifest)

    run_key =
      Keyword.get_lazy(opts, :run_key, fn ->
        "phase:#{manifest.provider}:#{System.unique_integer([:positive])}"
      end)

    run =
      ProviderRun
      |> Ash.Changeset.for_create(:create, %{
        provider_source_id: source.id,
        status: "queued",
        requested_by: Keyword.get(opts, :requested_by, "provider_ingestion_worker"),
        run_key: run_key,
        provenance:
          Map.merge(
            %{
              "manifest_provider" => manifest.provider,
              "destructive_apply" => false
            },
            Keyword.get(opts, :provenance, %{}) |> stringify_keys()
          )
      })
      |> Ash.create!(actor: @catalog_writer)

    {source, run}
  end

  def mark_phase(run_id, phase, status, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    run = Ash.get!(ProviderRun, run_id, authorize?: false)
    provenance = phase_provenance(run.provenance || %{}, phase, status, attrs, now)

    run_status = run_status(run.status, phase, status, provenance)

    params =
      %{
        status: run_status,
        provenance: provenance,
        started_at: run.started_at || now,
        source_count: Map.get(attrs, :source_count, run.source_count),
        snapshot_count: Map.get(attrs, :snapshot_count, run.snapshot_count),
        candidate_count: Map.get(attrs, :candidate_count, run.candidate_count),
        accepted_count: Map.get(attrs, :accepted_count, run.accepted_count),
        rejected_count: Map.get(attrs, :rejected_count, run.rejected_count),
        error_count: Map.get(attrs, :error_count, run.error_count)
      }
      |> maybe_put_finished_at(run_status, now, run.finished_at)

    updated =
      run
      |> Ash.Changeset.for_update(:record_progress, params)
      |> Ash.update!(actor: @catalog_writer)

    create_event!(updated, phase, status, attrs, now)
    Telemetry.phase_stop(updated, phase, status, attrs)
    updated
  end

  def cancelled?(run_id) when is_binary(run_id) do
    case Ash.get(ProviderRun, run_id, authorize?: false) do
      {:ok, %ProviderRun{status: "cancelled"}} -> true
      {:ok, %ProviderRun{}} -> false
      {:error, _error} -> false
    end
  end

  def mark_run_failed(run_id, phase, reason) when is_binary(run_id) do
    mark_phase(run_id, phase, :failed, %{
      error_count: 1,
      error: failure_error(reason),
      message: failure_message(phase, reason)
    })
  end

  defp ensure_provider_source!(manifest) do
    stable_source_key = stable_source_key(manifest)

    existing =
      ProviderSource
      |> Ash.Query.filter(stable_source_key == ^stable_source_key)
      |> Ash.read!(authorize?: false)
      |> List.first()

    existing || create_provider_source!(manifest, stable_source_key)
  end

  defp create_provider_source!(manifest, stable_source_key) do
    ProviderSource
    |> Ash.Changeset.for_create(:create, %{
      stable_source_key: stable_source_key,
      provider_name: manifest.name || manifest.provider,
      source_kind: "publisher",
      ingestion_mode: source_mode(manifest),
      base_uri: List.first(manifest.source_urls || []),
      manifest_uri: List.first(manifest.source_urls || []),
      allowed_hosts: manifest.source_hosts || [],
      rate_limit_per_minute: rate_limit_per_minute(manifest),
      max_bytes: get_in(manifest.rate_limit || %{}, [:max_bytes]),
      checksum_algorithm: "sha256",
      license_note: manifest.permission_basis,
      enabled?: true
    })
    |> Ash.create!(actor: @catalog_writer)
  end

  defp stable_source_key(manifest), do: "publisher:#{manifest.provider}:#{source_mode(manifest)}"

  defp source_mode(manifest) do
    case Hiraeth.Ingestion.ProviderManifest.effective_source_mode(manifest) do
      mode when mode in ["api", "scrape"] -> mode
      _ -> "manual"
    end
  end

  defp rate_limit_per_minute(manifest) do
    case get_in(manifest.rate_limit || %{}, [:min_delay_ms]) do
      delay when is_integer(delay) and delay > 0 -> max(div(60_000, delay), 1)
      _ -> 60
    end
  end

  defp phase_provenance(provenance, phase, status, attrs, now) do
    phase_payload =
      attrs
      |> Map.take([:source_count, :snapshot_count, :candidate_count, :error])
      |> stringify_keys()
      |> Map.merge(%{
        "status" => Atom.to_string(status),
        "occurred_at" => DateTime.to_iso8601(now),
        "destructive_apply" => false
      })

    provenance = stringify_keys(provenance)
    {provenance, phases} = normalize_phases(provenance)

    provenance
    |> Map.put("destructive_apply", false)
    |> Map.put("phases", Map.put(phases, Atom.to_string(phase), phase_payload))
  end

  defp run_status("cancelled", _phase, _status, _provenance), do: "cancelled"
  defp run_status(_current, _phase, :failed, _provenance), do: "failed"
  defp run_status(_current, :provider_ingestion_worker, :succeeded, _provenance), do: "succeeded"
  defp run_status("queued", _phase, :succeeded, _provenance), do: "running"

  defp run_status(current, _phase, :succeeded, _provenance) when current in ["queued", "running"],
    do: "running"

  defp run_status("failed", _phase, :succeeded, provenance) do
    if failed_phase?(provenance), do: "failed", else: "running"
  end

  defp run_status(current, _phase, _status, _provenance), do: current

  defp failed_phase?(provenance) do
    provenance
    |> Map.get("phases", %{})
    |> Enum.any?(fn {_phase, payload} -> Map.get(payload, "status") == "failed" end)
  end

  defp maybe_put_finished_at(params, status, now, _finished_at)
       when status in ["succeeded", "failed"] do
    Map.put(params, :finished_at, now)
  end

  defp maybe_put_finished_at(params, "cancelled", _now, finished_at),
    do: Map.put(params, :finished_at, finished_at)

  defp maybe_put_finished_at(params, _status, _now, _finished_at),
    do: Map.put(params, :finished_at, nil)

  defp create_event!(run, phase, status, attrs, now) do
    IngestionEvent
    |> Ash.Changeset.for_create(:create, %{
      provider_run_id: run.id,
      provider_source_id: run.provider_source_id,
      source_snapshot_id: Map.get(attrs, :source_snapshot_id),
      event_kind: "phase:#{phase}",
      status: Atom.to_string(status),
      message: Map.get(attrs, :message, default_message(phase, status)),
      payload: attrs |> Map.drop([:message]) |> stringify_keys(),
      occurred_at: now
    })
    |> Ash.create!(actor: @catalog_writer)
  end

  defp default_message(phase, status), do: "#{phase} #{status}"

  defp normalize_phases(%{"phases" => phases} = provenance) when is_map(phases) do
    {provenance, phases}
  end

  defp normalize_phases(%{"phases" => phases} = provenance) when is_list(phases) do
    provenance =
      provenance
      |> Map.put_new("planned_phases", phases)
      |> Map.delete("phases")

    {provenance, %{}}
  end

  defp normalize_phases(%{"phases" => phases} = provenance) do
    provenance =
      provenance
      |> Map.put_new("legacy_phases", phases)
      |> Map.delete("phases")

    {provenance, %{}}
  end

  defp normalize_phases(provenance), do: {provenance, %{}}

  defp failure_error({code, message}) when is_atom(code),
    do: %{code: code, message: message}

  defp failure_error(reason), do: %{code: :provider_ingestion_failed, message: inspect(reason)}

  defp failure_message(phase, reason) when is_binary(reason), do: "#{phase} failed: #{reason}"
  defp failure_message(phase, reason), do: "#{phase} failed: #{inspect(reason)}"

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
