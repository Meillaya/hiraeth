defmodule Hiraeth.Ingestion.CoverCandidateRun do
  @moduledoc false

  alias Hiraeth.Ingestion.{
    ProviderRun,
    ProviderSource,
    RecordCandidate,
    SourceSnapshot
  }

  alias Hiraeth.Ingestion.CoverCandidateRun.Finalizer

  require Ash.Query

  @catalog_writer %{id: "provider-ingestion-worker", catalog_write?: true}

  def cache_dataset_covers(dataset, manifest, pipeline) do
    cover_urls =
      extract_cover_urls(dataset.records, manifest.provider, manifest.cover_hosts || [])

    cond do
      cover_urls == [] ->
        {:ok, %{}}

      strict_cover_cache?(manifest) or
          not function_exported?(pipeline, :cache_cover_candidates!, 2) ->
        cache_legacy_covers(pipeline, cover_urls, manifest, provider_config(manifest))

      true ->
        cache_candidate_covers(cover_urls, dataset, manifest, pipeline, provider_config(manifest))
    end
  end

  defp cache_legacy_covers(pipeline, cover_urls, manifest, provider_config) do
    case pipeline.download_and_cache!(cover_urls, provider_config) do
      {:ok, cover_paths} ->
        Finalizer.emit_legacy_cover_cache(:succeeded, cover_urls, cover_paths, [], manifest)

        {:ok, cover_paths}

      {:error, failed_covers} ->
        Finalizer.emit_legacy_cover_cache(:failed, cover_urls, %{}, failed_covers, manifest)

        {:error, "cover cache failed: #{inspect(failed_covers)}"}
    end
  end

  defp cache_candidate_covers(cover_urls, dataset, manifest, pipeline, provider_config) do
    provider_source = ensure_provider_source!(manifest)
    provider_run = create_cover_provider_run!(provider_source, dataset, manifest)

    try do
      source_snapshot =
        ensure_cover_source_snapshot!(provider_source, provider_run, dataset, manifest)

      cover_candidates = create_cover_candidates!(cover_urls, provider_run, source_snapshot)

      case pipeline.cache_cover_candidates!(cover_candidates, provider_config) do
        {:ok, cover_summary} ->
          Finalizer.mark_succeeded!(provider_run, cover_candidates, cover_summary)
          {:ok, cover_summary}

        {:error, failed_covers} ->
          Finalizer.mark_failed!(provider_run, cover_candidates, failed_covers)
          {:error, "cover cache failed: #{inspect(failed_covers)}"}
      end
    rescue
      error ->
        Finalizer.mark_failed!(provider_run, [], [Exception.message(error)])
        reraise error, __STACKTRACE__
    end
  end

  defp provider_config(manifest) do
    %{
      max_concurrency: manifest.rate_limit[:max_concurrency] || 4,
      max_body_size: manifest.rate_limit[:max_bytes] || 10_485_760,
      strict?: strict_cover_cache?(manifest)
    }
  end

  defp strict_cover_cache?(manifest) do
    manifest.cover_cache_policy in ["strict", "strict_cache_required", "all_or_nothing"]
  end

  defp extract_cover_urls(records, provider, allowed_cover_hosts) do
    records
    |> Enum.filter(fn record ->
      is_map(record[:cover]) and present?(record[:cover][:source_url])
    end)
    |> Enum.map(fn record ->
      cover = record[:cover]

      %{
        source_url: cover[:source_url],
        provider: provider,
        rights_basis: cover[:rights_basis] || "local_cache_permitted",
        attribution_text: cover[:attribution_text],
        allowed_cover_hosts: allowed_cover_hosts
      }
    end)
  end

  defp ensure_provider_source!(manifest) do
    stable_source_key = "publisher:#{manifest.provider}:manifest"

    case provider_source_by_stable_key(stable_source_key) do
      nil ->
        ProviderSource
        |> Ash.Changeset.for_create(:create, %{
          stable_source_key: stable_source_key,
          provider_name: manifest.name || manifest.provider,
          source_kind: "publisher",
          ingestion_mode: manifest.source_mode || "manifest",
          base_uri: List.first(manifest.source_urls || []),
          manifest_uri: List.first(manifest.source_urls || []),
          allowed_hosts: manifest.source_hosts || [],
          rate_limit_per_minute: rate_limit_per_minute(manifest),
          max_bytes: manifest.rate_limit[:max_bytes] || 10_485_760,
          license_note: manifest.permission_basis || "provider manifest ingestion",
          enabled?: true
        })
        |> Ash.create!(actor: @catalog_writer)

      source ->
        source
    end
  end

  defp provider_source_by_stable_key(stable_source_key) do
    ProviderSource
    |> Ash.Query.filter(stable_source_key == ^stable_source_key)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp create_cover_provider_run!(provider_source, dataset, manifest) do
    ProviderRun
    |> Ash.Changeset.for_create(:create, %{
      provider_source_id: provider_source.id,
      status: "running",
      requested_by: "provider_ingestion_worker",
      run_key: "cover-cache-#{dataset.file_checksum}-#{System.unique_integer([:positive])}",
      provenance: %{
        "provider" => manifest.provider,
        "file_checksum" => dataset.file_checksum,
        "cover_cache" => true
      },
      started_at: DateTime.utc_now(:second)
    })
    |> Ash.create!(actor: @catalog_writer)
  end

  defp ensure_cover_source_snapshot!(provider_source, provider_run, dataset, manifest) do
    source_uri =
      "#{dataset.file_path || List.first(manifest.source_urls || []) || manifest.provider}#cover-cache-#{provider_run.id}"

    SourceSnapshot
    |> Ash.Changeset.for_create(:create, %{
      provider_source_id: provider_source.id,
      provider_run_id: provider_run.id,
      provider: manifest.provider,
      source_uri: source_uri,
      content_checksum: dataset.file_checksum,
      fetched_at: DateTime.utc_now(:second),
      http_status: 200,
      content_type: "application/json",
      byte_size: byte_size(Jason.encode!(dataset.records || [])),
      raw_payload: %{"record_count" => length(dataset.records || [])},
      source_mode: manifest.source_mode,
      storage_ref: "provider-ingestion/#{manifest.provider}/#{dataset.file_checksum}.json"
    })
    |> Ash.create!(actor: @catalog_writer)
  end

  defp create_cover_candidates!(cover_urls, provider_run, source_snapshot) do
    cover_urls
    |> Enum.with_index(1)
    |> Enum.map(fn {cover, index} ->
      metadata = %{
        "source_url" => cover.source_url,
        "provider" => cover.provider,
        "rights_basis" => cover.rights_basis,
        "cache_policy" => "cache_allowed",
        "attribution_text" => cover.attribution_text,
        "allowed_cover_hosts" => cover.allowed_cover_hosts
      }

      RecordCandidate
      |> Ash.Changeset.for_create(:create, %{
        provider_run_id: provider_run.id,
        source_snapshot_id: source_snapshot.id,
        candidate_identity: "cover:#{sha256("#{cover.source_url}:#{index}")}",
        record_type: "cover",
        source_uri: cover.source_url,
        raw_metadata: metadata,
        normalized_metadata: metadata,
        validation_errors: [],
        validation_findings: []
      })
      |> Ash.create!(actor: @catalog_writer)
    end)
  end

  defp rate_limit_per_minute(manifest) do
    case manifest.rate_limit[:max_concurrency] do
      value when is_integer(value) and value > 0 -> value * 60
      _value -> 60
    end
  end

  defp present?(value), do: value not in [nil, "", []]

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
