defmodule Hiraeth.RealCatalog.Dataset do
  @moduledoc """
  Reads tracked real-publisher catalog dataset files from `priv/catalog_sources`.
  """

  @dataset_dir Application.app_dir(:hiraeth, "priv/catalog_sources/real_publishers")
  @source_authority_manifest_file "source_authority_manifest.json"

  def default_dir, do: @dataset_dir
  def source_authority_manifest_file, do: @source_authority_manifest_file

  def load_dir(dir \\ @dataset_dir) do
    dir
    |> dataset_files()
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, datasets} ->
      case load_file(file) do
        {:ok, dataset} -> {:cont, {:ok, [dataset | datasets]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, datasets} -> {:ok, Enum.reverse(datasets)}
      error -> error
    end
  end

  def load_file(file) do
    with {:ok, body} <- File.read(file),
         {:ok, decoded} <- Jason.decode(body) do
      dataset =
        decoded
        |> atomize()
        |> Map.put(:file, Path.basename(file))
        |> Map.put(:file_path, file)
        |> Map.put(:file_checksum, sha256(body))

      {:ok, dataset}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, file, error}}
      {:error, reason} -> {:error, {reason, file}}
    end
  end

  def load_source_authority_manifest(dir \\ @dataset_dir) do
    path = Path.join(dir, @source_authority_manifest_file)

    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, path, error}}
      {:error, :enoent} -> {:error, {:not_found, path}}
      {:error, reason} -> {:error, {reason, path}}
    end
  end

  @non_dataset_files MapSet.new([
                       "schema.json",
                       @source_authority_manifest_file,
                       "source_artifacts_manifest.json",
                       "source_coverage_report.json"
                     ])

  def dataset_files(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) in @non_dataset_files))
    |> Enum.sort()
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {"field_sources", value} -> {:field_sources, atomize_field_sources(value)}
      {key, value} -> {atom_key(key), atomize(value)}
    end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp atomize_field_sources(sources) when is_map(sources) do
    Map.new(sources, fn {field, value} -> {to_string(field), atomize(value)} end)
  end

  defp atomize_field_sources(value), do: atomize(value)

  @known_keys ~w(
    provider retrieved_at license_note provider_permissions records prose_curation scope updated_at records_with_prose
    file source_uri source_product_id source_sku missing_fields reason series slug position label
    publisher imprint work title subtitle original_title original_language_code subjects publication_state description synopsis
    storefront_url editorial_praise review_links excerpt quote source source_uri edition format published_on isbn_13 language_code page_count dimensions height_mm width_mm depth_mm
    contributors name role cover source_url rights_basis attribution_text
    attribution_url cache_policy no_cover_reason cover_fallback_reason displayed_fields curation status
    notes file_path file_checksum field_sources source_type permission_basis cover_cache_policy source_urls source_hosts cover_hosts excluded_content takedown_contact not_legal_advice
  )
  @known_atoms Map.new(@known_keys, &{&1, String.to_atom(&1)})

  defp atom_key(key) when is_atom(key), do: key

  defp atom_key(key) when is_binary(key) do
    Map.get(@known_atoms, key, key)
  end

  defp sha256(body) do
    body
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
