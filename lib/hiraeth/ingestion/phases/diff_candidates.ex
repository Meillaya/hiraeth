defmodule Hiraeth.Ingestion.Phases.DiffCandidates do
  @moduledoc """
  Writes normalized record candidates and classifies diffs without catalog apply.
  """

  alias Hiraeth.Ingestion.{RecordCandidate, SourceSnapshot}
  alias Hiraeth.Ingestion.Phases.RunState
  alias Hiraeth.RealCatalog.SourceIdentity
  alias Hiraeth.Sources.SourceRecord

  require Ash.Query

  def run(
        %{
          dataset: %{records: records},
          manifest: manifest,
          provider_run_id: run_id,
          source_snapshot: snapshot
        } = context
      ) do
    current_identities = MapSet.new(records, &candidate_identity(manifest.provider, &1))

    candidates =
      records
      |> Enum.map(&create_candidate!(&1, manifest, run_id, snapshot))
      |> Kernel.++(removed_candidates!(manifest, run_id, snapshot, current_identities))

    RunState.mark_phase(run_id, :diff_candidates, :succeeded, %{
      candidate_count: length(candidates),
      snapshot_count: 1,
      source_count: length(records)
    })

    {:ok,
     Map.merge(context, %{record_candidates: candidates, candidate_count: length(candidates)})}
  rescue
    error ->
      RunState.mark_phase(context.provider_run_id, :diff_candidates, :failed, %{
        error_count: 1,
        error: %{code: :diff_failed, message: Exception.message(error)}
      })

      {:error, {:diff_failed, Exception.message(error)}}
  end

  defp create_candidate!(record, manifest, run_id, %SourceSnapshot{} = snapshot) do
    normalized = stringify(record)
    identity = candidate_identity(manifest.provider, record)
    previous = previous_candidate(identity, run_id)
    fingerprint = RecordCandidate.fingerprint_for!(normalized)
    previous_fingerprint = previous && previous.fingerprint

    diff_classification =
      cond do
        is_nil(previous_fingerprint) -> "new"
        previous_fingerprint == fingerprint -> "unchanged"
        true -> "changed"
      end

    attrs =
      %{
        provider_run_id: run_id,
        source_snapshot_id: snapshot.id,
        candidate_identity: identity,
        record_type: "edition",
        source_uri: source_uri(record),
        previous_fingerprint: previous_fingerprint,
        diff_classification: diff_classification,
        raw_metadata: normalized,
        normalized_metadata: normalized,
        validation_errors: [],
        validation_findings: []
      }
      |> Map.merge(review_attrs(record, diff_classification))

    RecordCandidate
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: RunState.catalog_writer())
  end

  defp review_attrs(record, diff_classification) do
    if approved_record?(record) and not RecordCandidate.destructive_diff?(diff_classification) do
      %{
        review_status: "accepted",
        review_decision: "approved",
        quarantine_status: "clear",
        reviewer_note: "Approved by provider record curation status."
      }
    else
      %{}
    end
  end

  defp approved_record?(record), do: get_in_map(record, [:curation, :status]) == "approved"

  defp previous_candidate(identity, run_id) do
    RecordCandidate
    |> Ash.Query.filter(candidate_identity == ^identity and provider_run_id != ^run_id)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> List.first()
  end

  defp removed_candidates!(manifest, run_id, %SourceSnapshot{} = snapshot, current_identities) do
    manifest.provider
    |> previous_source_records()
    |> Enum.reject(&MapSet.member?(current_identities, previous_identity(manifest.provider, &1)))
    |> Enum.map(&create_removed_candidate!(&1, manifest, run_id, snapshot))
  end

  defp previous_source_records(provider) do
    SourceRecord
    |> Ash.Query.filter(provider == ^provider and source_type == "publisher_dataset")
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(&previous_identity(provider, &1))
    |> Enum.map(fn {_identity, records} ->
      Enum.max_by(records, & &1.imported_at, DateTime)
    end)
  end

  defp previous_identity(provider, %SourceRecord{} = source_record) do
    source_record.source_identity || "#{provider}:#{source_record.source_uri}"
  end

  defp create_removed_candidate!(
         %SourceRecord{} = source_record,
         manifest,
         run_id,
         %SourceSnapshot{} = snapshot
       ) do
    removed_payload = stringify(source_record.raw_payload || %{})
    previous_fingerprint = RecordCandidate.fingerprint_for!(removed_payload)

    RecordCandidate
    |> Ash.Changeset.for_create(:create, %{
      provider_run_id: run_id,
      source_snapshot_id: snapshot.id,
      candidate_identity: previous_identity(manifest.provider, source_record),
      record_type: "edition",
      source_uri: source_record.source_uri,
      previous_fingerprint: previous_fingerprint,
      diff_classification: "removed",
      raw_metadata: removed_payload,
      normalized_metadata: removed_payload,
      validation_errors: [],
      validation_findings: [
        %{
          "code" => "missing_from_current_snapshot",
          "message" => "Previously imported source identity is absent from current candidate set."
        }
      ],
      reviewer_note: "Generated from prior SourceRecord missing in current source snapshot."
    })
    |> Ash.create!(actor: RunState.catalog_writer())
  end

  defp candidate_identity(provider, record), do: SourceIdentity.for_record(provider, record)

  defp source_uri(record),
    do: map_value(record, :source_uri) || "unknown:#{:erlang.phash2(record)}"

  defp get_in_map(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      if is_map(current), do: {:cont, map_value(current, key)}, else: {:halt, nil}
    end)
  end

  defp map_value(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil

  defp stringify(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
