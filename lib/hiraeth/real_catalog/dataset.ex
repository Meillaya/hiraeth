defmodule Hiraeth.RealCatalog.Dataset do
  @moduledoc """
  Reads tracked real-publisher catalog dataset files from `priv/catalog_sources`.
  """

  @dataset_dir Application.app_dir(:hiraeth, "priv/catalog_sources/real_publishers")

  def default_dir, do: @dataset_dir

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

  def dataset_files(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "schema.json"))
    |> Enum.sort()
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  @known_keys ~w(
    provider retrieved_at license_note records file source_uri source_product_id source_sku
    publisher imprint work title subtitle original_title publication_state edition format
    published_on isbn_13 contributors name role cover source_url rights_basis attribution_text
    attribution_url cache_policy no_cover_reason cover_fallback_reason displayed_fields curation status
    notes file_path file_checksum
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
