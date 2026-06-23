defmodule Mix.Tasks.Hiraeth.Scrape do
  @moduledoc """
  Scrape a provider catalog via the Scrapling sidecar and stage a dataset JSON file.

  Usage:
      mix hiraeth.scrape --provider <slug> [--manifest <path>]

  The manifest defaults to priv/catalog_sources/provider_manifests/<slug>.json.
  The staged dataset is written to priv/catalog_sources/staged/<slug>.json.

  This task does not import records into the catalog; it only produces the staged
  dataset wrapper so downstream tasks can review and apply it.
  """
  use Mix.Task

  alias Hiraeth.Ingestion.{ProviderManifest, SidecarClient}
  alias Hiraeth.Oban.ProviderIngestionWorker
  alias Hiraeth.RealCatalog.{Dataset, SourcePolicy, Validator}

  @shortdoc "Scrape a provider and stage a dataset JSON file"

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
          manifest: :string
        ]
      )

    provider = Keyword.get(opts, :provider)

    if is_nil(provider) or String.trim(provider) == "" do
      {:error, "Usage: mix hiraeth.scrape --provider <slug> [--manifest <path>]"}
    else
      manifest_path = Keyword.get(opts, :manifest, default_manifest_path(provider))
      scrape_provider(provider, manifest_path)
    end
  end

  defp default_manifest_path(provider) do
    Path.join(ProviderManifest.default_dir(), "#{provider}.json")
  end

  defp scrape_provider(provider, manifest_path) do
    with {:ok, manifest} <- load_manifest(manifest_path),
         :ok <- check_sidecar_health(),
         {:ok, records} <- fetch_scraped_records(manifest),
         {:ok, dataset} <- build_and_validate_dataset(provider, records, manifest),
         staged_path <- staged_dataset_path(provider),
         :ok <- write_dataset(staged_path, dataset) do
      print_summary(provider, records, staged_path)
      :ok
    end
  end

  defp load_manifest(manifest_path) do
    try do
      manifest = ProviderManifest.load!(manifest_path)
      # Register the manifest with SourcePolicy so validation can use its hosts.
      SourcePolicy.load_provider_manifest(manifest_path)
      {:ok, manifest}
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

  defp fetch_scraped_records(manifest) do
    client = sidecar_client()

    provider_config = %{
      provider: manifest.provider,
      config: build_sidecar_config(manifest)
    }

    case client.scrape(provider_config) do
      {:ok, %{records: records}} when is_list(records) ->
        {:ok, Dataset.normalize(records)}

      {:error, reason} when is_binary(reason) ->
        {:error, "sidecar scrape failed: #{reason}"}

      {:error, reason} ->
        {:error, "sidecar scrape failed: #{inspect(reason)}"}
    end
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
          auth: manifest.api[:auth]
        })
      else
        config
      end

    config =
      if is_map(manifest.spider) and manifest.spider != %{} do
        Map.put(config, :spider, %{
          module: manifest.spider[:module],
          start_urls: manifest.spider[:start_urls],
          selectors: manifest.spider[:selectors]
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

  defp build_and_validate_dataset(provider, records, manifest) do
    staged_path = staged_dataset_path(provider)

    dataset = %{
      provider: manifest.provider,
      records: records,
      file: Path.basename(staged_path),
      file_path: staged_path,
      file_checksum: ProviderIngestionWorker.compute_file_checksum(records),
      license_note: "sidecar_scrape",
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

    case Validator.validate_datasets([dataset]) do
      {:ok, _summary} ->
        {:ok, dataset}

      {:error, findings} ->
        {:error, format_validation_findings(findings)}
    end
  end

  defp staged_dataset_path(provider) do
    base_dir = Application.app_dir(:hiraeth, "priv/catalog_sources/staged")
    Path.join(base_dir, "#{provider}.json")
  end

  defp write_dataset(staged_path, dataset) do
    File.mkdir_p!(Path.dirname(staged_path))
    File.write!(staged_path, Jason.encode!(dataset, pretty: true))
    :ok
  rescue
    error -> {:error, "failed to write staged dataset: #{Exception.message(error)}"}
  end

  defp print_summary(provider, records, staged_path) do
    cover_count =
      records
      |> Enum.filter(fn record ->
        is_map(record[:cover]) and is_binary(record[:cover][:source_url])
      end)
      |> length()

    Mix.shell().info("Staged dataset for provider: #{provider}")
    Mix.shell().info("records=#{length(records)}")
    Mix.shell().info("covers=#{cover_count}")
    Mix.shell().info("staged_file=#{staged_path}")
  end

  defp format_validation_findings(findings) do
    formatted =
      findings
      |> Enum.take(10)
      |> Enum.map_join("\n", fn finding ->
        "  - #{format_finding(finding)}"
      end)

    rest =
      if length(findings) > 10 do
        "\n  ... and #{length(findings) - 10} more"
      else
        ""
      end

    "validation failed:\n#{formatted}#{rest}"
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

  defp sidecar_client do
    Application.get_env(:hiraeth, :sidecar_client, SidecarClient)
  end
end
