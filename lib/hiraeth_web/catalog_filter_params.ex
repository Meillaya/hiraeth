defmodule HiraethWeb.CatalogFilterParams do
  @moduledoc false

  @filter_params ~w(q publisher role contributor format language subject series year sort)

  def blank do
    Map.new(@filter_params, &{&1, ""})
  end

  def from_request(params) do
    filters = Map.take(params, @filter_params)
    query = Map.get(filters, "q", "")

    %{
      filters: filters,
      form_params: blank() |> Map.merge(filters) |> Map.put("q", query),
      page: Map.get(params, "page", "1"),
      query: query
    }
  end

  def filtered_path(base_path, params) do
    params =
      params
      |> Map.take(@filter_params)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    case params do
      map when map == %{} -> base_path
      map -> base_path <> "?" <> URI.encode_query(map)
    end
  end
end
