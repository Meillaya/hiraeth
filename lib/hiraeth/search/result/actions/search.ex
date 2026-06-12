defmodule Hiraeth.Search.Result.Actions.Search do
  use Ash.Resource.ManualRead

  alias Hiraeth.Catalog.Edition
  alias Hiraeth.Search.Result

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    search_text =
      query
      |> Ash.Query.get_argument(:query)
      |> to_string()
      |> String.trim()

    with {:ok, editions} <- read_editions(context) do
      results =
        editions
        |> Enum.map(&to_result/1)
        |> Enum.filter(&matches?(&1, search_text))
        |> Enum.sort_by(&sort_key/1)

      full_count = length(results)
      sliced_results = Enum.slice(results, page_offset(query), page_limit(query))

      {:ok, sliced_results, %{full_count: full_count}}
    end
  end

  defp read_editions(context) do
    Edition
    |> Ash.Query.for_read(:read)
    |> Ash.Query.load([
      :publisher,
      :imprint,
      :identifiers,
      contributions: [:contributor],
      work: [series_memberships: [:series], contributions: [:contributor]]
    ])
    |> Ash.read(authorize?: Map.get(context, :authorize?, true), actor: Map.get(context, :actor))
  end

  defp to_result(edition) do
    work = loaded_or_nil(edition.work)
    publisher = loaded_or_nil(edition.publisher)
    imprint = loaded_or_nil(edition.imprint)

    %Result{
      id: edition.id,
      edition_id: edition.id,
      work_id: work.id,
      title: edition.title,
      subtitle: edition.subtitle,
      slug: edition.slug,
      publisher_name: publisher.name,
      imprint_name: if(imprint, do: imprint.name),
      contributor_names: contributor_names(edition, work),
      series_titles: series_titles(work),
      identifiers: identifiers(edition),
      published_on: edition.published_on
    }
  end

  defp contributor_names(edition, work) do
    edition.contributions
    |> concat_loaded(work && work.contributions)
    |> Enum.sort_by(&{&1.position || 0, &1.role, &1.id})
    |> Enum.map(&loaded_or_nil(&1.contributor))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.display_name)
    |> Enum.uniq()
  end

  defp series_titles(nil), do: []

  defp series_titles(work) do
    work.series_memberships
    |> loaded_list()
    |> Enum.sort_by(&{&1.position || 0, &1.id})
    |> Enum.map(&loaded_or_nil(&1.series))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.title)
    |> Enum.uniq()
  end

  defp identifiers(edition) do
    edition.identifiers
    |> loaded_list()
    |> Enum.sort_by(&{&1.identifier_type, &1.value})
    |> Enum.map(& &1.value)
  end

  defp matches?(_result, ""), do: true

  defp matches?(result, search_text) do
    needle = normalize_text(search_text)
    isbn_needle = normalize_identifier(search_text)

    searchable_text =
      [
        result.title,
        result.subtitle,
        result.publisher_name,
        result.imprint_name,
        result.contributor_names,
        result.series_titles,
        result.identifiers
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &to_string/1)
      |> normalize_text()

    searchable_identifiers =
      result.identifiers
      |> Enum.map_join(" ", &normalize_identifier/1)

    String.contains?(searchable_text, needle) or
      (isbn_needle != "" and String.contains?(searchable_identifiers, isbn_needle))
  end

  defp sort_key(result) do
    {normalize_text(result.title), result.published_on || ~D[9999-12-31], result.id}
  end

  defp page_limit(%{limit: limit}) when is_integer(limit) and limit > 0, do: limit
  defp page_limit(%{page: %{limit: limit}}) when is_integer(limit) and limit > 0, do: limit
  defp page_limit(_query), do: 20

  defp page_offset(%{offset: offset}) when is_integer(offset) and offset >= 0, do: offset
  defp page_offset(%{page: %{offset: offset}}) when is_integer(offset) and offset >= 0, do: offset
  defp page_offset(_query), do: 0

  defp concat_loaded(left, right), do: loaded_list(left) ++ loaded_list(right)

  defp loaded_list(%Ash.NotLoaded{}), do: []
  defp loaded_list(nil), do: []
  defp loaded_list(list) when is_list(list), do: list

  defp loaded_or_nil(%Ash.NotLoaded{}), do: nil
  defp loaded_or_nil(value), do: value

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_identifier(value) do
    value
    |> to_string()
    |> String.replace(~r/[^0-9xX]/, "")
    |> String.downcase()
  end
end
