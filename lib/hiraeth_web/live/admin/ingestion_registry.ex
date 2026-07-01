defmodule HiraethWeb.Admin.IngestionRegistry do
  @moduledoc false

  alias Hiraeth.Ingestion.{IngestionEvent, ProviderRun, ProviderSource, SourceSnapshot}

  require Ash.Query

  @provider_limit 100
  @run_limit 12
  @event_limit 200
  @snapshot_limit 50
  alias HiraethWeb.Admin.IngestionFormat

  def load(params) when is_map(params) do
    selected_artifact = selected_artifact(params["artifact_id"])
    selected_provider_id = selected_provider_id(params["id"], selected_artifact)
    providers = list_providers(selected_provider_id)
    selected_provider = select_provider(providers, selected_provider_id)
    provider_runs = list_runs(selected_provider, selected_artifact)
    events = list_events(provider_runs)
    snapshots = list_snapshots(provider_runs, selected_artifact)

    %{
      providers: providers,
      provider_count: length(providers),
      enabled_count: Enum.count(providers, & &1.enabled?),
      selected_provider: selected_provider,
      selected_artifact: selected_artifact_in_scope(selected_artifact, snapshots),
      provider_runs: provider_runs,
      run_count: length(provider_runs),
      artifact_count: length(snapshots),
      events_by_run: Enum.group_by(events, & &1.provider_run_id),
      snapshots_by_run: Enum.group_by(snapshots, & &1.provider_run_id),
      phase_statuses: phase_statuses(provider_runs, events)
    }
  end

  def update_provider_enabled(provider_id, enabled?, actor) do
    with {:ok, provider} <- get_provider(provider_id) do
      provider
      |> Ash.Changeset.for_update(:update, %{enabled?: enabled?})
      |> Ash.update(actor: actor)
    end
  end

  def get_provider(provider_id) when is_binary(provider_id) and provider_id != "" do
    with {:ok, provider_uuid} <- Ecto.UUID.cast(provider_id) do
      case Ash.get(ProviderSource, provider_uuid, authorize?: false) do
        {:ok, %ProviderSource{} = provider} -> {:ok, provider}
        {:ok, nil} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid}
    end
  end

  def get_provider(_provider_id), do: {:error, :invalid}

  defp list_providers(selected_provider_id) do
    providers =
      ProviderSource
      |> Ash.Query.sort(provider_name: :asc, stable_source_key: :asc)
      |> Ash.Query.limit(@provider_limit)
      |> Ash.read!(authorize?: false)

    selected_provider_id
    |> provider_for_id()
    |> prepend_missing_provider(providers)
    |> Enum.sort_by(&String.downcase(&1.provider_name || ""))
  end

  defp selected_artifact(nil), do: nil

  defp selected_artifact(artifact_id) when is_binary(artifact_id) and artifact_id != "" do
    case Ash.get(SourceSnapshot, artifact_id, authorize?: false) do
      {:ok, %SourceSnapshot{} = snapshot} -> snapshot
      _other -> nil
    end
  end

  defp selected_artifact(_artifact_id), do: nil

  defp selected_provider_id(nil, selected_artifact),
    do: selected_artifact && selected_artifact.provider_source_id

  defp selected_provider_id("", selected_artifact),
    do: selected_artifact && selected_artifact.provider_source_id

  defp selected_provider_id(provider_id, _selected_artifact), do: provider_id

  defp select_provider([], _selected_provider_id), do: nil

  defp select_provider(providers, selected_provider_id) do
    Enum.find(providers, &(to_string(&1.id) == to_string(selected_provider_id))) ||
      List.first(providers)
  end

  defp provider_for_id(nil), do: nil
  defp provider_for_id(""), do: nil

  defp provider_for_id(provider_id) do
    case get_provider(to_string(provider_id)) do
      {:ok, provider} -> provider
      {:error, _reason} -> nil
    end
  end

  defp prepend_missing_provider(nil, providers), do: providers

  defp prepend_missing_provider(provider, providers) do
    if Enum.any?(providers, &(&1.id == provider.id)), do: providers, else: [provider | providers]
  end

  defp selected_artifact_in_scope(nil, _snapshots), do: nil

  defp selected_artifact_in_scope(selected_artifact, snapshots) do
    Enum.find(snapshots, &(&1.id == selected_artifact.id))
  end

  defp list_runs(nil, _selected_artifact), do: []

  defp list_runs(provider, selected_artifact) do
    runs =
      ProviderRun
      |> Ash.Query.filter(provider_source_id == ^provider.id)
      |> Ash.Query.sort(started_at: :desc, inserted_at: :desc)
      |> Ash.Query.limit(@run_limit)
      |> Ash.read!(authorize?: false)

    selected_artifact
    |> run_for_artifact(provider)
    |> prepend_missing_run(runs)
    |> Enum.sort_by(
      &(&1.started_at || &1.inserted_at || DateTime.from_unix!(0)),
      {:desc, DateTime}
    )
  end

  defp run_for_artifact(nil, _provider), do: nil

  defp run_for_artifact(selected_artifact, provider) do
    if selected_artifact.provider_source_id == provider.id do
      case Ash.get(ProviderRun, selected_artifact.provider_run_id, authorize?: false) do
        {:ok, %ProviderRun{} = run} -> run
        _other -> nil
      end
    end
  end

  defp prepend_missing_run(nil, runs), do: runs

  defp prepend_missing_run(run, runs) do
    if Enum.any?(runs, &(&1.id == run.id)), do: runs, else: [run | runs]
  end

  defp list_events([]), do: []

  defp list_events(runs) do
    run_ids = Enum.map(runs, & &1.id)

    IngestionEvent
    |> Ash.Query.filter(provider_run_id in ^run_ids)
    |> Ash.Query.sort(occurred_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(@event_limit)
    |> Ash.read!(authorize?: false)
  end

  defp list_snapshots([], _selected_artifact), do: []

  defp list_snapshots(runs, selected_artifact) do
    run_ids = Enum.map(runs, & &1.id)

    snapshots =
      SourceSnapshot
      |> Ash.Query.filter(provider_run_id in ^run_ids)
      |> Ash.Query.sort(fetched_at: :desc, inserted_at: :desc)
      |> Ash.Query.limit(@snapshot_limit)
      |> Ash.read!(authorize?: false)

    selected_artifact
    |> snapshot_in_runs(run_ids)
    |> prepend_missing_snapshot(snapshots)
    |> Enum.sort_by(& &1.fetched_at, {:desc, DateTime})
  end

  defp snapshot_in_runs(nil, _run_ids), do: nil

  defp snapshot_in_runs(selected_artifact, run_ids) do
    if selected_artifact.provider_run_id in run_ids, do: selected_artifact
  end

  defp prepend_missing_snapshot(nil, snapshots), do: snapshots

  defp prepend_missing_snapshot(snapshot, snapshots) do
    if Enum.any?(snapshots, &(&1.id == snapshot.id)), do: snapshots, else: [snapshot | snapshots]
  end

  defp phase_statuses(runs, events) do
    runs
    |> Enum.flat_map(&phase_statuses_for_run(&1, events))
    |> Enum.uniq_by(& &1.name)
    |> Enum.take(8)
  end

  defp phase_statuses_for_run(run, events) do
    event_phases =
      events
      |> Enum.filter(
        &(&1.provider_run_id == run.id and String.starts_with?(&1.event_kind, "phase:"))
      )
      |> Enum.map(fn event ->
        phase = String.replace_prefix(event.event_kind, "phase:", "")

        %{
          name: phase,
          dom_id: IngestionFormat.dom_id(phase),
          status: event.status,
          message:
            event.message || "Recorded at #{IngestionFormat.format_datetime(event.occurred_at)}"
        }
      end)

    event_phases ++ provenance_phase_statuses(run.provenance)
  end

  defp provenance_phase_statuses(phases) when is_map(phases) do
    phases
    |> Map.get("phases", %{})
    |> Enum.map(fn {phase, payload} ->
      status = if is_map(payload), do: Map.get(payload, "status", "planned"), else: "planned"

      %{
        name: phase,
        dom_id: IngestionFormat.dom_id(phase),
        status: status,
        message: "Status recorded in run provenance."
      }
    end)
  end

  defp provenance_phase_statuses(_phases), do: []
end
