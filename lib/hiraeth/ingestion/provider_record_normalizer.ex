defmodule Hiraeth.Ingestion.ProviderRecordNormalizer do
  @moduledoc false

  alias Hiraeth.Ingestion.Telemetry
  alias Hiraeth.RealCatalog.Dataset

  require Logger

  @detail_enrichment_providers MapSet.new([
                                 "deep_vellum",
                                 "deep_vellum_official_store",
                                 "two_lines_press_official_store"
                               ])

  def normalize(records, manifest, client) do
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
            Telemetry.sidecar_error("detail", :malformed_response, %{provider: provider})

            Logger.warning(
              "sidecar detail enrichment returned malformed response for #{source_uri}: #{inspect(detail)}"
            )

            {:unchanged, record}

          {:error, reason} ->
            Telemetry.sidecar_error("detail", detail_error_code(reason), %{provider: provider})

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

  defp detail_error_code({code, _message}) when is_atom(code), do: code
  defp detail_error_code(reason) when is_atom(reason), do: reason
  defp detail_error_code(_reason), do: :detail_failed

  defp inspect_detail_reason(reason) when is_binary(reason), do: reason
  defp inspect_detail_reason(reason), do: inspect(reason)

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
end
