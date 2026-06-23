defmodule Hiraeth.Oban.ProviderIngestionWorker do
  @moduledoc """
  Oban worker that orchestrates full provider ingestion end-to-end.

  This is the core of the ingestion orchestration system. A single job
  processes one provider manifest: fetch/scrape records from the sidecar,
  validate them, cache covers, import into the catalog, and run a
  provenance audit — all-or-nothing.

  ## Unique Job

  Only one job per provider can be enqueued at a time. Duplicate
  enqueues for the same provider are silently rejected.

  ## Idempotency

  The worker checks for existing SourceRecords by provider before
  importing. If records already exist, the import is skipped.

  ## Rate Limiting

  If the sidecar returns a rate-limit error, the job snoozes and
  retries after a delay.
  """

  use Oban.Worker,
    queue: :ingestion,
    unique: [
      keys: [:provider],
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      period: :infinity
    ]

  alias Hiraeth.Ingestion.{CoverPipeline, ProviderManifest, SidecarClient}
  alias Hiraeth.RealCatalog.{Dataset, Importer, SourcePolicy, Validator}
  alias Hiraeth.ProvenanceAudit
  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.Sources.SourceRecord

  require Ash.Query
  require Logger

  @detail_enrichment_providers MapSet.new([
                                 "deep_vellum",
                                 "deep_vellum_official_store",
                                 "two_lines_press_official_store"
                               ])

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    manifest_path = args["manifest_path"]

    with {:ok, manifest} <- load_manifest(manifest_path),
         {:ok, _provider} <- register_provider(manifest_path),
         {:ok, records} <- fetch_records(manifest),
         {:ok, dataset} <- validate_records(records, manifest, manifest_path),
         {:ok, _covers} <- cache_covers(dataset, manifest),
         {:ok, _import} <- import_provider(dataset),
         {:ok, _audit} <- run_audit(manifest.provider) do
      {:ok,
       %{
         provider: manifest.provider,
         record_count: length(records),
         source_mode: manifest.source_mode
       }}
    end
  end

  # --- Step 1: Load manifest ---

  defp load_manifest(manifest_path) do
    manifest = ProviderManifest.load!(manifest_path)
    {:ok, manifest}
  rescue
    error -> {:error, "manifest load failed: #{Exception.message(error)}"}
  end

  # --- Step 2: Register provider in SourcePolicy ---

  defp register_provider(manifest_path) do
    SourcePolicy.load_provider_manifest(manifest_path)
  end

  # --- Step 3: Fetch or scrape records from sidecar ---

  defp fetch_records(manifest) do
    provider_config = %{
      provider: manifest.provider,
      config: build_sidecar_config(manifest)
    }

    client = sidecar_client()

    case ProviderManifest.effective_source_mode(manifest) do
      "scrape" ->
        case client.scrape(provider_config) do
          {:ok, %{records: records}} when records != [] ->
            process_successful_records(records, manifest, client)

          scrape_result ->
            if has_api_config?(manifest) do
              client.fetch(provider_config)
              |> process_api_fallback_result(manifest, client)
            else
              to_scrape_error(scrape_result)
            end
        end

      "api" ->
        client.fetch(provider_config)
        |> process_final_result("fetch", manifest, client)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_final_result({:ok, %{records: records}}, _source_label, manifest, client) do
    process_successful_records(records, manifest, client)
  end

  defp process_final_result({:error, reason}, source_label, _manifest, _client)
       when is_binary(reason) do
    if rate_limit_error?(reason) do
      {:snooze, rate_limit_snooze_seconds()}
    else
      {:error, "sidecar #{source_label} failed: #{reason}"}
    end
  end

  defp process_final_result({:error, reason}, source_label, _manifest, _client) do
    {:error, "sidecar #{source_label} failed: #{inspect(reason)}"}
  end

  defp process_api_fallback_result({:ok, %{records: records}}, manifest, client) do
    process_successful_records(records, manifest, client)
  end

  defp process_api_fallback_result(result, manifest, client) do
    process_final_result(result, "fetch (scrape fallback)", manifest, client)
  end

  def normalize_provider_records(records, manifest, client) do
    {records, enriched_count} = enrich_detail_records(records, manifest, client)
    records = dedupe_records_by_isbn(records)

    if enriched_count > 0 do
      Logger.warning("enriched detail for #{enriched_count} records")
    end

    {:ok, Dataset.normalize(records)}
  end

  defp dedupe_records_by_isbn(records) do
    {_seen, records} =
      Enum.reduce(records, {MapSet.new(), []}, fn record, {seen, kept} ->
        isbn = normalized_isbn(record)

        if is_nil(isbn) or not MapSet.member?(seen, isbn) do
          {if(is_nil(isbn), do: seen, else: MapSet.put(seen, isbn)), [record | kept]}
        else
          {seen, kept}
        end
      end)

    Enum.reverse(records)
  end

  defp normalized_isbn(record) do
    case Hiraeth.RealCatalog.ISBN.normalize(get_in_map(record, [:edition, :isbn_13])) do
      {:ok, isbn} -> isbn
      {:error, _reason} -> nil
    end
  end

  defp process_successful_records(records, manifest, client) do
    normalize_provider_records(records, manifest, client)
  end

  defp to_scrape_error({:ok, %{records: []}}) do
    {:error, "sidecar scrape returned empty records"}
  end

  defp to_scrape_error({:error, reason}) when is_binary(reason) do
    if rate_limit_error?(reason) do
      {:snooze, rate_limit_snooze_seconds()}
    else
      {:error, "sidecar scrape failed: #{reason}"}
    end
  end

  defp to_scrape_error({:error, reason}) do
    {:error, "sidecar scrape failed: #{inspect(reason)}"}
  end

  defp has_api_config?(manifest) do
    api = Map.get(manifest, :api) || Map.get(manifest, "api") || %{}
    is_map(api) and api != %{} and not is_nil(api[:type])
  end

  defp build_sidecar_config(manifest) do
    config = %{}

    config =
      if is_map(manifest.api) and manifest.api != %{} do
        config
        |> Map.put(:source_hosts, manifest.source_hosts)
        |> Map.put(:publisher_name, manifest.name)
        |> Map.put(:api, %{
          type: manifest.api[:type],
          endpoint: manifest.api[:endpoint],
          auth: manifest.api[:auth],
          allowed_vendors: manifest.api[:allowed_vendors]
        })
      else
        config
      end

    config =
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

  defp rate_limit_error?(reason) do
    reason = String.downcase(reason)
    String.contains?(reason, "429") or String.contains?(reason, "rate limit")
  end

  defp rate_limit_snooze_seconds, do: 60

  defp enrich_detail_records(records, manifest, client) do
    detail_opts = detail_enrichment_opts(manifest)

    Enum.map_reduce(records, 0, fn record, enriched_count ->
      case enrich_detail_record(record, manifest.provider, client, detail_opts) do
        {:enriched, record} -> {record, enriched_count + 1}
        {:unchanged, record} -> {record, enriched_count}
      end
    end)
  end

  defp detail_enrichment_opts(manifest) do
    max_bytes = get_in(manifest.rate_limit || %{}, [:max_bytes])
    opts = [enabled: manifest.detail_enrichment == true]

    if is_integer(max_bytes) and max_bytes > 0 do
      Keyword.put(opts, :max_bytes, max_bytes)
    else
      opts
    end
  end

  defp enrich_detail_record(record, provider, client, detail_opts) do
    if detail_enrichment_provider?(provider, detail_opts) and needs_detail_enrichment?(record) and
         function_exported?(client, :detail, 3) do
      source_uri = map_value(record, :source_uri)

      if is_binary(source_uri) and present?(source_uri) do
        case client.detail(source_uri, provider, Keyword.delete(detail_opts, :enabled)) do
          {:ok, detail} when is_map(detail) ->
            merge_detail(record, detail, provider)

          {:ok, detail} ->
            Logger.warning(
              "sidecar detail enrichment returned malformed response for #{source_uri}: #{inspect(detail)}"
            )

            {:unchanged, record}

          {:error, reason} ->
            Logger.warning(
              "sidecar detail enrichment failed for #{source_uri}: #{inspect_detail_reason(reason)}"
            )

            {:unchanged, record}
        end
      else
        {:unchanged, record}
      end
    else
      {:unchanged, record}
    end
  end

  defp merge_detail(record, detail, provider) do
    original = record

    record =
      record
      |> put_missing(:contributors, map_value(detail, :contributors))
      |> put_missing(:description, map_value(detail, :description))
      |> put_missing_edition_field(:isbn_13, map_value(detail, :isbn_13))
      |> put_missing_edition_field(:published_on, map_value(detail, :published_on))
      |> put_missing_cover_source(map_value(detail, :cover), provider)

    if record == original do
      {:unchanged, record}
    else
      {:enriched, record}
    end
  end

  defp needs_detail_enrichment?(record) do
    blank_contributors?(map_value(record, :contributors)) or
      blank?(get_in_map(record, [:cover, :source_url])) or
      blank?(get_in_map(record, [:edition, :isbn_13])) or
      blank?(get_in_map(record, [:edition, :published_on]))
  end

  defp detail_enrichment_provider?(provider, opts) do
    Keyword.get(opts, :enabled, false) or
      MapSet.member?(@detail_enrichment_providers, to_string(provider))
  end

  defp put_missing(map, key, value) do
    if blank?(map_value(map, key)) and present?(value) do
      Map.put(map, existing_key(map, key), value)
    else
      map
    end
  end

  defp put_missing_edition_field(record, field, value) do
    edition = map_value(record, :edition) || %{}

    if is_map(edition) and blank?(map_value(edition, field)) and present?(value) do
      edition = Map.put(edition, existing_key(edition, field), value)
      Map.put(record, existing_key(record, :edition), edition)
    else
      record
    end
  end

  defp put_missing_cover_source(record, cover_detail, provider) when is_map(cover_detail) do
    source_url = map_value(cover_detail, :source_url)
    cover = map_value(record, :cover) || %{}

    if is_map(cover) and blank?(map_value(cover, :source_url)) and present?(source_url) do
      cover =
        cover
        |> Map.put(existing_key(cover, :source_url), source_url)
        |> put_missing(:provider, provider)
        |> put_missing(:rights_basis, "local_cache_permitted")
        |> put_missing(:cache_policy, "cache_allowed")

      Map.put(record, existing_key(record, :cover), cover)
    else
      record
    end
  end

  defp put_missing_cover_source(record, _cover_detail, _provider), do: record

  defp blank_contributors?(value), do: value in [nil, []]

  defp blank?(value), do: value in [nil, "", []]
  defp present?(value), do: not blank?(value)

  defp get_in_map(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      if is_map(current) do
        {:cont, map_value(current, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp existing_key(map, key) do
    cond do
      Map.has_key?(map, key) -> key
      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) -> Atom.to_string(key)
      true -> key
    end
  end

  defp inspect_detail_reason(reason) when is_binary(reason), do: reason
  defp inspect_detail_reason(reason), do: inspect(reason)

  # --- Step 4: Validate records ---

  @doc """
  Computes a content-derived SHA-256 checksum for a list of records.
  """
  def compute_file_checksum(records) do
    records
    |> Dataset.normalize()
    |> Enum.sort_by(fn record ->
      record[:source_uri] || record["source_uri"] || ""
    end)
    |> Jason.encode!(pretty: false)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_records(records, manifest, manifest_path) do
    dataset = %{
      provider: manifest.provider,
      records: records,
      file: Path.basename(manifest_path),
      file_path: manifest_path,
      file_checksum: compute_file_checksum(records),
      license_note: "sidecar_import",
      provider_permissions: %{
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
    }

    with :ok <- validate_expected_record_count(records, manifest),
         {:ok, _summary} <- Validator.validate_datasets([dataset]) do
      {:ok, dataset}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_expected_record_count(records, manifest) do
    expected = manifest.expected_record_count
    actual = length(records)

    if is_integer(expected) and expected != actual do
      {:error, "expected_record_count #{expected} does not match fetched record count #{actual}"}
    else
      :ok
    end
  end

  # --- Step 5: Cache covers ---

  defp cache_covers(dataset, manifest) do
    cover_urls =
      extract_cover_urls(dataset.records, manifest.provider, manifest.cover_hosts || [])

    if cover_urls == [] do
      {:ok, %{}}
    else
      provider_config = %{
        max_concurrency: manifest.rate_limit[:max_concurrency] || 4,
        max_body_size: manifest.rate_limit[:max_bytes] || 10_485_760
      }

      case cover_pipeline().download_and_cache!(cover_urls, provider_config) do
        {:ok, cover_paths} ->
          {:ok, cover_paths}

        {:error, failed_covers} ->
          {:error, "cover cache failed: #{inspect(failed_covers)}"}
      end
    end
  rescue
    error -> {:error, "cover cache failed: #{Exception.message(error)}"}
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

  # --- Step 6: Import provider ---

  defp import_provider(dataset) do
    if existing_source_records?(dataset.file_checksum) do
      {:ok, :skipped_existing}
    else
      import_run = ensure_import_run!(dataset)
      importer().seed_provider!(dataset, import_run)
    end
  rescue
    error -> {:error, "import failed: #{Exception.message(error)}"}
  end

  defp existing_source_records?(file_checksum) do
    SourceRecord
    |> Ash.Query.filter(file_checksum: file_checksum)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  defp ensure_import_run!(dataset) do
    ImportRun
    |> Ash.Changeset.for_create(:create, %{
      provider: dataset.provider,
      status: "applied",
      row_limit: length(dataset.records || [])
    })
    |> Ash.create!(authorize?: false)
  end

  # --- Step 7: Run provenance audit ---

  defp run_audit(provider) do
    ProvenanceAudit.run!(providers: [provider])
    {:ok, :audited}
  rescue
    error -> {:error, "audit failed: #{Exception.message(error)}"}
  end

  # --- Injectable dependencies for testing ---

  defp sidecar_client do
    Application.get_env(:hiraeth, :sidecar_client, SidecarClient)
  end

  defp cover_pipeline do
    Application.get_env(:hiraeth, :cover_pipeline, CoverPipeline)
  end

  defp importer do
    Application.get_env(:hiraeth, :importer, Importer)
  end
end
