defmodule Hiraeth.Ingestion.ProviderManifest do
  @moduledoc """
  Defines the ProviderManifest struct and loads/validates provider config manifests
  from JSON files in `priv/catalog_sources/provider_manifests/`.
  """

  alias Hiraeth.Ingestion.ManifestValidator

  defstruct [
    :provider,
    :name,
    :source_mode,
    :source_urls,
    :source_hosts,
    :cover_hosts,
    :api,
    :spider,
    :rate_limit,
    :expected_record_count,
    :permission_basis,
    :takedown_contact,
    :excluded_content,
    :cover_cache_policy,
    :not_legal_advice
  ]

  @manifest_dir Application.app_dir(:hiraeth, "priv/catalog_sources/provider_manifests")

  @doc """
  Returns the default directory for provider manifest JSON files.
  """
  def default_dir, do: @manifest_dir

  @doc """
  Loads a provider manifest JSON file, validates it, and returns a `%ProviderManifest{}` struct.

  Raises on file read errors, JSON decode errors, or validation failures.
  """
  def load!(file_path) do
    body = File.read!(file_path)

    decoded =
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        {:error, error} -> raise "invalid JSON in #{file_path}: #{inspect(error)}"
      end

    atomized = atomize(decoded)

    case ManifestValidator.validate(atomized) do
      {:ok, _manifest} ->
        struct!(__MODULE__, atomized)

      {:error, findings} ->
        reasons = Enum.map_join(findings, "\n", &"  - #{&1.reason}")
        raise "manifest validation failed for #{file_path}:\n#{reasons}"
    end
  end

  @doc """
  Returns the effective source_mode for a manifest.

  Rules:
  - explicit source_mode: "api" -> "api"
  - explicit source_mode: "scrape" -> "scrape"
  - absent + spider config present -> "scrape"
  - absent + only api config present -> "api"
  - otherwise -> {:error, "source_mode is required"}
  """
  def effective_source_mode(manifest) when is_map(manifest) do
    mode = get_field(manifest, :source_mode)
    api = get_field(manifest, :api) || %{}
    spider = get_field(manifest, :spider) || %{}

    cond do
      present?(mode) and mode == "api" -> "api"
      present?(mode) and mode == "scrape" -> "scrape"
      present?(mode) -> {:error, "source_mode must be \"api\" or \"scrape\""}
      map_present?(spider) -> "scrape"
      map_present?(api) -> "api"
      true -> {:error, "source_mode is required"}
    end
  end

  # --- Atomize helpers (mirror Dataset.atomize pattern) ---

  @known_keys ~w(
    provider name source_mode source_urls source_hosts cover_hosts
    api spider rate_limit expected_record_count permission_basis
    takedown_contact excluded_content cover_cache_policy not_legal_advice
    type endpoint auth allowed_vendors source_handle_patterns host path_prefix handle_pattern module start_urls selectors
    max_concurrency min_delay_ms max_bytes
    method key_env book title author
  )
  @known_atoms Map.new(@known_keys, &{&1, String.to_atom(&1)})

  defp atomize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp atom_key(key) when is_atom(key), do: key

  defp atom_key(key) when is_binary(key) do
    Map.get(@known_atoms, key, key)
  end

  defp get_field(manifest, key) when is_atom(key) do
    Map.get(manifest, key) || Map.get(manifest, to_string(key))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp map_present?(value), do: is_map(value) and value != %{} and value != nil
end
