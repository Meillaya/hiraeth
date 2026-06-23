defmodule Mix.Tasks.Hiraeth.Ingest do
  @moduledoc """
  Ingest a new publisher's book metadata and covers.

  Usage:
      mix hiraeth.ingest --provider <slug> [--manifest <path>]

  The manifest defaults to priv/catalog_sources/provider_manifests/<slug>.json.
  """
  use Mix.Task

  alias Hiraeth.Ingestion.ProviderManifest
  alias Hiraeth.Ingestion.SidecarClient
  alias Hiraeth.Oban.ProviderIngestionWorker
  alias Hiraeth.RealCatalog.{SourcePolicy, Validator}

  require Ash.Query

  @shortdoc "Ingest a new publisher's book metadata and covers"

  @poll_interval 2_000
  @max_timeout_ms :timer.minutes(30)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case do_run(args) do
      :ok ->
        :ok

      {:error, message} ->
        Mix.shell().error(format_error_message(message))
        exit({:shutdown, 1})
    end
  end

  @doc false
  def do_run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          provider: :string,
          manifest: :string,
          dry_run: :boolean
        ]
      )

    provider = Keyword.get(opts, :provider)

    if is_nil(provider) or String.trim(provider) == "" do
      {:error, "Usage: mix hiraeth.ingest --provider <slug> [--manifest <path>] [--dry-run]"}
    else
      manifest_path = Keyword.get(opts, :manifest, default_manifest_path(provider))

      if Keyword.get(opts, :dry_run) do
        run_dry_run(provider, manifest_path)
      else
        run_ingestion(provider, manifest_path)
      end
    end
  end

  defp default_manifest_path(provider) do
    Path.join(ProviderManifest.default_dir(), "#{provider}.json")
  end

  defp run_ingestion(provider, manifest_path) do
    with :ok <- load_and_validate_manifest(manifest_path),
         :ok <- check_sidecar_health(),
         {:ok, job} <- enqueue_job(provider, manifest_path),
         :ok <- poll_and_report(job.id, provider) do
      :ok
    end
  end

  defp load_and_validate_manifest(manifest_path) do
    try do
      _manifest = ProviderManifest.load!(manifest_path)
      :ok
    rescue
      error in [RuntimeError] ->
        {:error, Exception.message(error)}

      error ->
        {:error, "manifest load failed: #{Exception.message(error)}"}
    end
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

  defp sidecar_client do
    Application.get_env(:hiraeth, :sidecar_client, SidecarClient)
  end

  defp enqueue_job(provider, manifest_path) do
    args = %{provider: provider, manifest_path: manifest_path}

    job =
      ProviderIngestionWorker.new(args)
      |> Oban.insert!()

    Mix.shell().info("Ingestion started for provider: #{provider}")
    Mix.shell().info("Job ID: #{job.id}")
    {:ok, job}
  end

  defp poll_and_report(job_id, provider) do
    deadline = System.monotonic_time(:millisecond) + @max_timeout_ms

    case poll_loop(job_id, deadline) do
      {:ok, _job} ->
        print_summary(provider)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp poll_loop(job_id, deadline) do
    now = System.monotonic_time(:millisecond)

    if now > deadline do
      {:error, "Ingestion timed out after #{div(@max_timeout_ms, 1000)} seconds"}
    else
      case Hiraeth.Repo.get(Oban.Job, job_id) do
        nil ->
          {:error, "Job #{job_id} not found"}

        %{state: "completed"} = job ->
          {:ok, job}

        %{state: "discarded"} = job ->
          {:error, format_discarded_error(job)}

        %{state: "cancelled"} ->
          {:error, "Job #{job_id} was cancelled"}

        _other ->
          Process.sleep(@poll_interval)
          poll_loop(job_id, deadline)
      end
    end
  end

  defp format_discarded_error(%{errors: errors}) when is_list(errors) do
    last_error = List.last(errors) || %{}
    error_msg = last_error["error"] || last_error[:error] || "unknown error"
    "Ingestion failed: #{error_msg}"
  end

  defp format_discarded_error(_job) do
    "Ingestion failed: unknown error"
  end

  defp print_summary(provider) do
    Mix.shell().info("Ingestion completed for provider: #{provider}")

    source_count = count_source_records(provider)
    edition_count = count_editions(provider)
    cover_count = count_covers(provider)

    Mix.shell().info("source_records=#{source_count}")
    Mix.shell().info("editions=#{edition_count}")
    Mix.shell().info("covers=#{cover_count}")
  end

  defp run_dry_run(provider, manifest_path) do
    with :ok <- load_and_validate_manifest(manifest_path),
         {:ok, _provider} <- register_provider(manifest_path),
         :ok <- check_sidecar_health(),
         {:ok, manifest} <- load_manifest(manifest_path),
         {:ok, records} <- fetch_records(manifest) do
      validate_and_print_dry_run(provider, records, manifest, manifest_path)
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

  defp load_manifest(manifest_path) do
    try do
      {:ok, ProviderManifest.load!(manifest_path)}
    rescue
      error -> {:error, "manifest load failed: #{Exception.message(error)}"}
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

  defp format_error_message(message) when is_binary(message), do: message
  defp format_error_message(message), do: inspect(message)

  defp count_source_records(provider) do
    Hiraeth.Sources.SourceRecord
    |> Ash.Query.filter(provider: provider)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp count_editions(provider) do
    import Ecto.Query

    count =
      from(e in Hiraeth.Catalog.Edition,
        join: sr in Hiraeth.Sources.SourceRecord,
        on: sr.edition_id == e.id,
        where: sr.provider == ^provider,
        select: count(e.id, :distinct)
      )
      |> Hiraeth.Repo.one()

    count || 0
  end

  defp count_covers(provider) do
    Hiraeth.Covers.CoverAsset
    |> Ash.Query.filter(provider: provider)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
