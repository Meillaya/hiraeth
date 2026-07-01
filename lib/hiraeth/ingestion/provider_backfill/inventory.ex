defmodule Hiraeth.Ingestion.ProviderBackfill.Inventory do
  @moduledoc false

  alias Hiraeth.Ingestion.ProviderManifest
  alias Hiraeth.RealCatalog.{Dataset, SourcePolicy}

  @script_paths [
    "scripts/generate_full_catalog.py",
    "scripts/generate_full_catalog_deep_vellum.py",
    "scripts/extract_fitzcarraldo_catalog.py"
  ]

  def build(opts \\ []) do
    real_dir = Keyword.get(opts, :real_publishers_dir, Dataset.default_dir())
    manifest_dir = Keyword.get(opts, :provider_manifests_dir, ProviderManifest.default_dir())
    script_paths = Keyword.get(opts, :script_paths, default_script_paths())

    with {:ok, real_sources} <- real_sources(real_dir),
         {:ok, manifests} <- manifest_sources(manifest_dir) do
      script_metadata = script_metadata(script_paths)

      providers =
        real_sources
        |> Map.merge(manifests, fn _key, real_source, manifest_source ->
          merge_manifest(real_source, manifest_source)
        end)
        |> Enum.map(fn {provider, source} ->
          Map.put(source, :script_builder, Map.get(script_metadata, provider))
        end)
        |> Enum.sort_by(& &1.stable_source_key)

      {:ok, providers}
    end
  end

  defp real_sources(real_dir) do
    real_dir
    |> Dataset.dataset_files()
    |> Enum.reduce_while({:ok, %{}}, fn file, {:ok, sources} ->
      with {:ok, dataset} <- Dataset.load_file(file),
           {:ok, source} <- real_source(dataset) do
        {:cont, {:ok, Map.put(sources, source.stable_source_key, source)}}
      else
        {:error, reason} -> {:halt, {:error, format_error(reason)}}
      end
    end)
  end

  defp real_source(dataset) do
    provider = string_field(dataset, :provider)

    if blank?(provider) do
      {:error, "missing provider in #{dataset.file_path}"}
    else
      permissions = map_field(dataset, :provider_permissions)
      source_urls = list_field(permissions, :source_urls)

      {:ok,
       %{
         stable_source_key: provider,
         provider_name: provider_name(dataset, provider),
         source_kind: "publisher",
         ingestion_mode: "manual",
         base_uri: List.first(source_urls),
         manifest_uri: nil,
         allowed_hosts: provider_source_hosts(provider, permissions),
         rate_limit_per_minute: nil,
         max_bytes: nil,
         checksum_algorithm: "sha256",
         required_checksum: dataset.file_checksum,
         license_note: license_note(dataset, permissions),
         enabled?: false,
         cover_hosts: provider_cover_hosts(provider, permissions),
         posture: "paused_manual_fixture",
         sources: ["real_publishers/#{dataset.file}"]
       }}
    end
  end

  defp manifest_sources(manifest_dir) do
    manifest_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn file, {:ok, sources} ->
      try do
        manifest = ProviderManifest.load!(file)
        source = manifest_source(manifest, file)
        {:cont, {:ok, Map.put(sources, source.stable_source_key, source)}}
      rescue
        error -> {:halt, {:error, Exception.message(error)}}
      end
    end)
  end

  defp manifest_source(manifest, file) do
    mode = ProviderManifest.effective_source_mode(manifest)

    if is_tuple(mode), do: raise("invalid source_mode in #{file}: #{elem(mode, 1)}")

    %{
      stable_source_key: manifest.provider,
      provider_name: manifest.name,
      source_kind: "publisher",
      ingestion_mode: mode,
      base_uri: manifest_base_uri(manifest),
      manifest_uri: manifest_uri(file),
      allowed_hosts: sorted_list(manifest.source_hosts),
      rate_limit_per_minute: rate_limit_per_minute(manifest.rate_limit),
      max_bytes: get_in(manifest.rate_limit || %{}, [:max_bytes]),
      checksum_algorithm: "sha256",
      required_checksum: file_sha256!(file),
      license_note: manifest.permission_basis,
      enabled?: mode in ["api", "scrape"],
      cover_hosts: sorted_list(manifest.cover_hosts),
      posture: "manifest_#{mode}",
      sources: ["provider_manifests/#{Path.basename(file)}"]
    }
  end

  defp merge_manifest(real_source, manifest_source) do
    manifest_source
    |> Map.update!(:allowed_hosts, &Enum.sort(Enum.uniq(&1 ++ real_source.allowed_hosts)))
    |> Map.update!(:cover_hosts, &Enum.sort(Enum.uniq(&1 ++ real_source.cover_hosts)))
    |> Map.update!(:sources, &(real_source.sources ++ &1))
    |> Map.put(:required_checksum, manifest_source.required_checksum)
  end

  defp provider_name(dataset, provider) do
    dataset
    |> map_field(:records)
    |> first_record_publisher()
    |> case do
      nil ->
        provider
        |> String.replace("_", " ")
        |> String.replace(" official ", " ")
        |> String.capitalize()

      name ->
        name
    end
  end

  defp first_record_publisher(records) when is_list(records) do
    records
    |> Enum.find_value(&string_field(&1, :publisher))
    |> blank_to_nil()
  end

  defp first_record_publisher(_records), do: nil

  defp provider_source_hosts(provider, permissions) do
    provider
    |> SourcePolicy.source_hosts()
    |> MapSet.to_list()
    |> Kernel.++(list_field(permissions, :source_hosts))
    |> sorted_list()
  end

  defp provider_cover_hosts(provider, permissions) do
    provider
    |> SourcePolicy.cover_hosts()
    |> MapSet.to_list()
    |> Kernel.++(list_field(permissions, :cover_hosts))
    |> sorted_list()
  end

  defp license_note(dataset, permissions) do
    string_field(dataset, :license_note) ||
      string_field(permissions, :permission_basis) ||
      "Checked-in deterministic provider fixture; manual refresh only until a provider manifest enables ingestion."
  end

  defp manifest_base_uri(%{api: %{endpoint: endpoint}}) when is_binary(endpoint), do: endpoint
  defp manifest_base_uri(%{source_urls: [url | _rest]}) when is_binary(url), do: url
  defp manifest_base_uri(_manifest), do: nil

  defp manifest_uri(file) do
    Path.join(["priv", "catalog_sources", "provider_manifests", Path.basename(file)])
  end

  defp rate_limit_per_minute(%{min_delay_ms: delay}) when is_integer(delay) and delay > 0,
    do: max(1, div(60_000, delay))

  defp rate_limit_per_minute(_rate_limit), do: nil

  defp script_metadata(paths) do
    paths
    |> Enum.flat_map(&script_entries/1)
    |> Map.new()
  end

  defp script_entries(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> then(
        &Regex.scan(~r/"([a-z0-9_]+_official_(?:store|site))"/, &1, capture: :all_but_first)
      )
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.map(&{&1, Path.basename(path)})
    else
      []
    end
  end

  defp default_script_paths, do: Enum.map(@script_paths, &Path.expand(&1, File.cwd!()))

  defp map_field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_field(_value, _key), do: nil

  defp string_field(map, key) do
    case map_field(map, key) do
      value when is_binary(value) -> blank_to_nil(value)
      _value -> nil
    end
  end

  defp list_field(map, key) do
    case map_field(map, key) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _value -> []
    end
  end

  defp sorted_list(%MapSet{} = set), do: set |> MapSet.to_list() |> sorted_list()

  defp sorted_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp sorted_list(_values), do: []

  defp file_sha256!(file) do
    file
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp blank_to_nil(value) when is_binary(value) do
    if blank?(value), do: nil, else: String.trim(value)
  end

  defp blank_to_nil(_value), do: nil
end
