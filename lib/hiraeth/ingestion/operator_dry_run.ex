defmodule Hiraeth.Ingestion.OperatorDryRun do
  @moduledoc false

  alias Hiraeth.Ingestion.{OperatorJSON, OperatorManifest, ProviderManifest}
  alias Hiraeth.Ingestion.SidecarClient
  alias Hiraeth.Oban.ProviderIngestionWorker
  alias Hiraeth.RealCatalog.{SourcePolicy, Validator}

  def run(provider, manifest_path, opts) do
    with {:ok, manifest} <- OperatorManifest.load(manifest_path),
         :ok <- OperatorManifest.ensure_provider_matches(provider, manifest) do
      if json?(opts) do
        OperatorJSON.print(dry_run_plan(provider, manifest, manifest_path))
        :ok
      else
        with {:ok, _provider} <- register_provider(manifest_path),
             :ok <- check_sidecar_health(),
             {:ok, records} <- fetch_records(manifest) do
          validate_and_print_dry_run(provider, records, manifest, manifest_path)
        end
      end
    end
  end

  defp register_provider(manifest_path) do
    SourcePolicy.load_provider_manifest(manifest_path)
  end

  defp validate_and_print_dry_run(provider, records, manifest, manifest_path) do
    print_dry_run_summary(provider, records, manifest)

    case validate_dry_run_dataset(records, manifest, manifest_path) do
      {:ok, _summary} ->
        Mix.shell().info("Dry-run validation passed (no data persisted).")
        :ok

      {:error, findings} ->
        print_validation_findings(List.wrap(findings))
        Mix.shell().info("Dry-run completed with validation issues (no data persisted).")
        :ok
    end
  end

  defp fetch_records(manifest) do
    client = sidecar_client()

    with {:ok, source_mode} <- resolve_source_mode(manifest) do
      provider_config = %{
        provider: manifest.provider,
        config: build_sidecar_config(manifest, source_mode)
      }

      result =
        case source_mode do
          "api" -> client.fetch(provider_config)
          "scrape" -> client.scrape(provider_config)
        end

      case result do
        {:ok, %{records: records}} ->
          ProviderIngestionWorker.normalize_provider_records(records, manifest, client)

        {:error, reason} when is_binary(reason) ->
          {:error, "sidecar #{source_mode} failed: #{reason}"}

        {:error, reason} ->
          {:error, "sidecar #{source_mode} failed: #{inspect(reason)}"}
      end
    end
  end

  defp resolve_source_mode(manifest) do
    case ProviderManifest.effective_source_mode(manifest) do
      {:error, _reason} = error -> error
      mode when is_binary(mode) -> {:ok, mode}
    end
  end

  defp build_sidecar_config(manifest, source_mode) when is_binary(source_mode) do
    config = %{}

    config =
      if source_mode == "api" and is_map(manifest.api) do
        config
        |> Map.put(:source_hosts, manifest.source_hosts)
        |> Map.put(:publisher_name, manifest.name)
        |> Map.put(:api, Map.put_new(manifest.api, :allowed_vendors, nil))
      else
        config
      end

    config =
      if source_mode == "scrape" and is_map(manifest.spider) do
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

  defp validate_dry_run_dataset(records, manifest, manifest_path) do
    dataset = %{
      provider: manifest.provider,
      records: records,
      file: Path.basename(manifest_path),
      file_path: manifest_path,
      file_checksum: ProviderIngestionWorker.compute_file_checksum(records),
      license_note: "dry_run",
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
         {:ok, summary} <- Validator.validate_datasets([dataset]) do
      {:ok, summary}
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

  defp print_dry_run_summary(provider, records, manifest) do
    cover_count =
      records
      |> Enum.filter(fn record ->
        is_map(record[:cover]) and present?(record[:cover][:source_url])
      end)
      |> length()

    effective_mode = ProviderManifest.effective_source_mode(manifest)

    Mix.shell().info("Dry-run preview for provider: #{provider}")
    Mix.shell().info("effective_source_mode=#{effective_mode}")
    Mix.shell().info("records=#{length(records)}")
    Mix.shell().info("covers=#{cover_count}")

    case records do
      [first | _] ->
        title = get_in(first, [:work, :title]) || get_in(first, ["work", "title"])
        isbn = get_in(first, [:edition, :isbn_13]) || get_in(first, ["edition", "isbn_13"])
        Mix.shell().info("first_record_title=#{title}")
        Mix.shell().info("first_record_isbn=#{isbn}")

      [] ->
        :ok
    end
  end

  defp print_validation_findings(findings) do
    Mix.shell().info("")
    Mix.shell().info("Validation findings (showing first 10):")

    findings
    |> Enum.take(10)
    |> Enum.each(fn finding ->
      Mix.shell().info("  - #{format_finding(finding)}")
    end)

    if length(findings) > 10 do
      Mix.shell().info("  ... and #{length(findings) - 10} more")
    end
  end

  defp format_finding(%{source_uri: source_uri, reason: reason})
       when is_binary(source_uri) and source_uri != "" do
    "#{source_uri}: #{reason}"
  end

  defp format_finding(%{isbn_13: isbn, reason: reason})
       when is_binary(isbn) and isbn != "" do
    "ISBN #{isbn}: #{reason}"
  end

  defp format_finding(%{reason: reason}), do: reason
  defp format_finding(finding), do: inspect(finding)

  defp dry_run_plan(provider, manifest, manifest_path) do
    source_mode = source_mode(manifest)

    %{
      action: "ingest",
      dry_run: true,
      provider: provider,
      manifest_path: manifest_path,
      effective_source_mode: source_mode,
      provider_source: %{
        stable_source_key: "publisher:#{manifest.provider}:#{source_mode}",
        provider_name: manifest.name || manifest.provider,
        source_kind: "publisher",
        ingestion_mode: source_mode,
        base_uri: List.first(manifest.source_urls || []),
        allowed_hosts: manifest.source_hosts || []
      },
      run: %{
        status: "planned",
        requested_by: "mix hiraeth.ingest",
        run_key: operator_run_key("dry-run:#{manifest.provider}"),
        would_create_provider_run: true,
        destructive_apply: false,
        phases: [
          "fetch_snapshot",
          "normalize_candidates",
          "validate_candidates",
          "diff_candidates",
          "cover_candidates",
          "quarantine_run",
          "apply_candidates",
          "audit_run"
        ]
      }
    }
  end

  defp source_mode(manifest) do
    case ProviderManifest.effective_source_mode(manifest) do
      mode when is_binary(mode) -> mode
      {:error, reason} -> "invalid:#{reason}"
    end
  end

  defp sidecar_client do
    Application.get_env(:hiraeth, :sidecar_client, SidecarClient)
  end

  defp check_sidecar_health do
    case sidecar_client().health() do
      {:ok, %{status: "ok"}} ->
        :ok

      _error ->
        {:error,
         "Scrapling sidecar is not running. Start it with: docker compose up -d scrapling-sidecar"}
    end
  end

  defp json?(opts), do: Keyword.get(opts, :json, false)

  defp operator_run_key(provider) do
    "operator:#{provider}:#{System.system_time(:microsecond)}:#{System.unique_integer([:positive])}"
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
