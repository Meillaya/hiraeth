defmodule Hiraeth.RealCatalog.SourceIdentity do
  @moduledoc """
  Builds durable source identities shared by importer-created `SourceRecord`s and
  ingestion candidates.
  """

  alias Hiraeth.RealCatalog.ISBN

  def for_record(provider, record) when is_binary(provider) and is_map(record) do
    normalized_isbn(record) || source_product_identity(provider, record) ||
      source_uri_identity(provider, record)
  end

  def normalized_isbn(record) when is_map(record) do
    case ISBN.normalize(get_in_map(record, [:edition, :isbn_13])) do
      {:ok, isbn} -> isbn
      {:error, _reason} -> nil
    end
  end

  defp source_product_identity(provider, record) do
    case map_value(record, :source_product_id) do
      value when is_binary(value) and value != "" -> "source:#{provider}:#{value}"
      _value -> nil
    end
  end

  defp source_uri_identity(provider, record) do
    case map_value(record, :source_uri) do
      value when is_binary(value) and value != "" -> "source:#{provider}:#{value}"
      _value -> "source:#{provider}:unknown:#{:erlang.phash2(record)}"
    end
  end

  defp get_in_map(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      if is_map(current), do: {:cont, map_value(current, key)}, else: {:halt, nil}
    end)
  end

  defp map_value(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil
end
