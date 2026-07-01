defmodule Hiraeth.Ingestion.Phases.ApplyCandidates do
  @moduledoc """
  Applies only explicitly approved, non-destructive record candidates to the
  catalog, leaving quarantined/removal/destructive candidates as reviewable
  ingestion state instead of mutating public catalog rows.
  """

  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.Ingestion.RecordCandidate
  alias Hiraeth.Ingestion.Phases.{RunState, TombstoneCandidates}
  alias Hiraeth.RealCatalog.Importer

  require Ash.Query

  def run(%{provider_run_id: run_id, manifest: manifest} = context) when is_binary(run_id) do
    candidates = candidates_for_run(run_id)
    applyable = Enum.filter(candidates, &applyable?/1)
    blocked = candidates -- applyable

    with {:ok, tombstones} <- TombstoneCandidates.run(context, candidates),
         {:ok, summary} <- apply_records(applyable, manifest) do
      RunState.mark_phase(run_id, :apply_candidates, :succeeded, %{
        candidate_count: length(candidates),
        accepted_count: length(applyable),
        rejected_count: length(blocked),
        source_count: summary.source_count,
        message:
          "Applied #{length(applyable)} approved candidates; blocked #{length(blocked)} candidates."
      })

      {:ok,
       Map.merge(context, %{
         applied_candidates: applyable,
         blocked_candidates: blocked,
         tombstone_records: tombstones,
         apply_summary: summary
       })}
    else
      {:error, reason} ->
        RunState.mark_phase(run_id, :apply_candidates, :failed, %{
          error_count: 1,
          error: %{code: :apply_failed, message: inspect(reason)}
        })

        {:error, reason}
    end
  rescue
    error ->
      RunState.mark_phase(context.provider_run_id, :apply_candidates, :failed, %{
        error_count: 1,
        error: %{code: :apply_failed, message: Exception.message(error)}
      })

      {:error, {:apply_failed, Exception.message(error)}}
  end

  defp candidates_for_run(run_id) do
    RecordCandidate
    |> Ash.Query.filter(provider_run_id == ^run_id)
    |> Ash.read!(authorize?: false)
  end

  defp applyable?(%RecordCandidate{} = candidate) do
    candidate.review_decision == "approved" and candidate.quarantine_status == "clear" and
      candidate.diff_classification in ["new", "changed", "unchanged"]
  end

  defp apply_records([], _manifest), do: {:ok, %{source_count: 0, import: :skipped_empty}}

  defp apply_records(candidates, manifest) do
    candidates = Enum.reject(candidates, &(&1.diff_classification == "unchanged"))

    if candidates == [] do
      {:ok, %{source_count: 0, import: :skipped_unchanged}}
    else
      apply_changed_records(candidates, manifest)
    end
  end

  defp apply_changed_records(candidates, manifest) do
    records = Enum.map(candidates, & &1.normalized_metadata)
    dataset = dataset_for(manifest, candidates, records)

    import_run =
      ImportRun
      |> Ash.Changeset.for_create(:create, %{
        provider: dataset.provider,
        status: "applied",
        row_limit: length(records)
      })
      |> Ash.create!(actor: RunState.catalog_writer())

    case seed_provider(dataset, import_run) do
      {:ok, import_summary} -> {:ok, %{source_count: length(records), import: import_summary}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dataset_for(manifest, candidates, records) do
    provider = manifest.provider
    checksum = candidate_checksum(candidates)

    %{
      provider: provider,
      records: Hiraeth.RealCatalog.Dataset.normalize(records),
      file: "#{provider}-approved-candidates.json",
      file_path: "record_candidates:#{provider}",
      file_checksum: checksum,
      license_note: manifest.permission_basis || "approved provider candidate apply",
      provider_permissions: provider_permissions(manifest),
      ingestion_candidates_by_source_uri: candidate_provenance_by_source_uri(candidates)
    }
  end

  defp candidate_provenance_by_source_uri(candidates) do
    candidates
    |> Enum.flat_map(fn candidate ->
      provenance = candidate_provenance(candidate)

      candidate
      |> candidate_source_uris()
      |> Enum.map(&{&1, provenance})
    end)
    |> Map.new()
  end

  defp candidate_provenance(candidate) do
    %{
      "candidate_id" => candidate.id,
      "candidate_identity" => candidate.candidate_identity,
      "provider_run_id" => candidate.provider_run_id,
      "source_snapshot_id" => candidate.source_snapshot_id,
      "diff_classification" => candidate.diff_classification,
      "fingerprint" => candidate.fingerprint,
      "review_decision" => candidate.review_decision
    }
  end

  defp candidate_source_uris(candidate) do
    base_uri = source_uri(candidate.normalized_metadata) || candidate.source_uri
    isbn = get_in_map(candidate.normalized_metadata, ["edition", "isbn_13"])
    source_product_id = get_in_map(candidate.normalized_metadata, ["source_product_id"])

    [
      base_uri,
      isbn && "#{base_uri}#isbn-#{isbn}",
      source_product_id && "#{base_uri}#source-#{source_product_id}"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp source_uri(metadata) when is_map(metadata) do
    Map.get(metadata, "source_uri") || Map.get(metadata, :source_uri)
  end

  defp get_in_map(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      if is_map(current),
        do: {:cont, Map.get(current, key) || Map.get(current, String.to_atom(key))},
        else: {:halt, nil}
    end)
  end

  defp candidate_checksum(candidates) do
    candidates
    |> Enum.map(&%{id: &1.id, fingerprint: &1.fingerprint})
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp provider_permissions(manifest) do
    %{
      provider: manifest.provider,
      permission_basis: manifest.permission_basis,
      cover_cache_policy: manifest.cover_cache_policy,
      takedown_contact: manifest.takedown_contact,
      not_legal_advice: manifest.not_legal_advice,
      source_urls: manifest.source_urls,
      source_hosts: manifest.source_hosts,
      cover_hosts: manifest.cover_hosts,
      excluded_content: manifest.excluded_content
    }
  end

  defp seed_provider(dataset, import_run) do
    importer = importer()

    if Code.ensure_loaded?(importer) and function_exported?(importer, :seed_provider!, 3) do
      importer.seed_provider!(dataset, import_run, prune_stale?: false)
    else
      importer.seed_provider!(dataset, import_run)
    end
  end

  defp importer, do: Application.get_env(:hiraeth, :importer, Importer)
end
