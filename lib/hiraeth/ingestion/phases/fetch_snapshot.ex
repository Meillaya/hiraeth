defmodule Hiraeth.Ingestion.Phases.FetchSnapshot do
  @moduledoc """
  Fetches or scrapes provider records, retains a private source snapshot, and
  records the fetch phase state without applying catalog writes.
  """

  alias Hiraeth.Ingestion.{ProviderManifest, SidecarClient, SourceSnapshot, Telemetry}
  alias Hiraeth.RealCatalog.SourcePolicy
  alias Hiraeth.Ingestion.Phases.RunState

  require Ash.Query

  @rate_limit_snooze_seconds 60

  def run(%{manifest_path: manifest_path} = context) do
    with {:ok, manifest} <- load_manifest(manifest_path),
         {:ok, _policy_provider} <- register_source_policy(manifest_path),
         {:ok, source_id, run_id} <- source_and_run_ids(manifest, context) do
      context =
        Map.merge(context, %{
          manifest: manifest,
          provider_source_id: source_id,
          provider_run_id: run_id
        })

      case fetch_records(manifest) do
        {:ok, records, source_mode} ->
          snapshot = persist_snapshot!(source_id, run_id, manifest, source_mode, records)

          RunState.mark_phase(run_id, :fetch_snapshot, :succeeded, %{
            source_count: length(records),
            snapshot_count: 1,
            source_snapshot_id: snapshot.id
          })

          {:ok,
           Map.merge(context, %{
             source_snapshot: snapshot,
             source_mode: source_mode,
             raw_records: records
           })}

        {:snooze, seconds} ->
          {:snooze, seconds}

        {:error, reason} ->
          mark_failed(context, reason)
          {:error, reason}
      end
    else
      {:snooze, seconds} ->
        {:snooze, seconds}

      {:error, reason} ->
        mark_failed(context, reason)
        {:error, reason}
    end
  end

  defp load_manifest(path) do
    {:ok, ProviderManifest.load!(path)}
  rescue
    error -> {:error, {:manifest_load_failed, Exception.message(error)}}
  end

  defp register_source_policy(path), do: SourcePolicy.load_provider_manifest(path)

  defp source_and_run_ids(_manifest, %{provider_source_id: source_id, provider_run_id: run_id})
       when is_binary(source_id) and is_binary(run_id) do
    {:ok, source_id, run_id}
  end

  defp source_and_run_ids(manifest, _context) do
    {source, run} = RunState.ensure_source_and_run!(manifest)
    {:ok, source.id, run.id}
  end

  defp fetch_records(manifest) do
    provider_config = %{provider: manifest.provider, config: build_sidecar_config(manifest)}
    client = sidecar_client()

    case ProviderManifest.effective_source_mode(manifest) do
      "scrape" -> fetch_scrape_first(client, provider_config, manifest)
      "api" -> client.fetch(provider_config) |> final_result("fetch", "api")
      {:error, reason} -> {:error, {:invalid_source_mode, reason}}
    end
  end

  defp fetch_scrape_first(client, provider_config, manifest) do
    case client.scrape(provider_config) do
      {:ok, %{records: records}} when records != [] -> {:ok, records, "scrape"}
      scrape_result -> maybe_api_fallback(scrape_result, client, provider_config, manifest)
    end
  end

  defp maybe_api_fallback(scrape_result, client, provider_config, manifest) do
    if has_api_config?(manifest) do
      client.fetch(provider_config) |> final_result("fetch (scrape fallback)", "scrape")
    else
      scrape_result |> final_result("scrape", "scrape")
    end
  end

  defp final_result({:ok, %{records: records}}, _source_label, source_mode),
    do: {:ok, records, source_mode}

  defp final_result({:error, {:rate_limited, _message}}, source_label, _mode) do
    Telemetry.sidecar_error(source_label, :rate_limited)
    {:snooze, @rate_limit_snooze_seconds}
  end

  defp final_result({:error, {code, message}}, source_label, _mode) when is_atom(code) do
    Telemetry.sidecar_error(source_label, code)
    {:error, {code, message}}
  end

  defp final_result({:error, reason}, source_label, _mode) when is_binary(reason) do
    Telemetry.sidecar_error(source_label, :sidecar_failed)
    {:error, {:sidecar_failed, "sidecar #{source_label} failed: #{reason}"}}
  end

  defp final_result({:error, reason}, source_label, _mode) do
    Telemetry.sidecar_error(source_label, :sidecar_failed)
    {:error, {:sidecar_failed, "sidecar #{source_label} failed: #{inspect(reason)}"}}
  end

  defp persist_snapshot!(source_id, run_id, manifest, source_mode, records) do
    source_url = List.first(manifest.source_urls || []) || "provider:#{manifest.provider}"

    payload =
      Jason.encode!(%{provider: manifest.provider, source_mode: source_mode, records: records})

    artifact =
      SourceSnapshot.retain_artifact!(manifest.provider, source_url, payload, extension: ".json")

    existing =
      SourceSnapshot
      |> Ash.Query.filter(
        provider_source_id == ^source_id and source_uri == ^source_url and
          content_checksum == ^artifact.checksum
      )
      |> Ash.read!(authorize?: false)
      |> List.first()

    if existing do
      existing
    else
      create_snapshot!(source_id, run_id, manifest, source_url, source_mode, artifact, records)
    end
  end

  defp create_snapshot!(source_id, run_id, manifest, source_url, source_mode, artifact, records) do
    SourceSnapshot
    |> Ash.Changeset.for_create(:create, %{
      provider_source_id: source_id,
      provider_run_id: run_id,
      provider: manifest.provider,
      source_url: source_url,
      checksum: artifact.checksum,
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      http_metadata: %{"status" => 200, "headers" => %{"content-type" => ["application/json"]}},
      adapter_version: "sidecar-phase-v1",
      source_mode: source_mode,
      artifact_path: artifact.artifact_path,
      byte_size: artifact.byte_size,
      raw_payload: %{"record_count" => length(records)}
    })
    |> Ash.create!(actor: RunState.catalog_writer())
  end

  defp mark_failed(%{provider_run_id: run_id}, {code, message}) when is_binary(run_id) do
    RunState.mark_phase(run_id, :fetch_snapshot, :failed, %{
      error_count: 1,
      error: %{code: code, message: message}
    })
  end

  defp mark_failed(_context, _reason), do: :ok

  defp has_api_config?(manifest),
    do: is_map(manifest.api) and manifest.api != %{} and not is_nil(manifest.api[:type])

  defp build_sidecar_config(manifest) do
    %{}
    |> maybe_put_api(manifest)
    |> maybe_put_spider(manifest)
    |> maybe_put_rate_limit(manifest)
  end

  defp maybe_put_api(config, manifest) do
    if is_map(manifest.api) and manifest.api != %{} do
      config
      |> Map.put(:source_hosts, manifest.source_hosts)
      |> Map.put(:publisher_name, manifest.name)
      |> Map.put(:api, Map.put_new(manifest.api, :allowed_vendors, nil))
    else
      config
    end
  end

  defp maybe_put_spider(config, manifest) do
    if is_map(manifest.spider) and manifest.spider != %{} do
      Map.put(config, :spider, %{
        module: manifest.spider[:module],
        start_urls: manifest.spider[:start_urls],
        selectors: manifest.spider[:selectors],
        use_stealthy_fetcher: manifest.spider[:use_stealthy_fetcher]
      })
    else
      config
    end
  end

  defp maybe_put_rate_limit(config, manifest) do
    if is_map(manifest.rate_limit) do
      Map.put(config, :rate_limit, %{
        max_concurrency: manifest.rate_limit[:max_concurrency],
        min_delay_ms: manifest.rate_limit[:min_delay_ms],
        max_bytes: manifest.rate_limit[:max_bytes]
      })
    else
      config
    end
  end

  defp sidecar_client do
    Application.get_env(:hiraeth, :sidecar_client, SidecarClient)
  end
end
