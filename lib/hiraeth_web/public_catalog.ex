defmodule HiraethWeb.PublicCatalog do
  @moduledoc """
  Ash-backed read model for public LiveView catalog pages.

  The module deliberately projects only known persisted fields. It never fills in
  unknown dates, languages, dimensions, page counts, translators, or cover art.
  """

  alias Hiraeth.Catalog.{Edition, Publisher, Series}
  alias Hiraeth.Covers
  alias Hiraeth.Sources.SourceRecord

  @page_size 2

  def page_size, do: @page_size

  def editions do
    Edition
    |> Ash.Query.for_read(:read)
    |> Ash.Query.load([
      :publisher,
      :identifiers,
      cover_assignments: [:cover_asset],
      contributions: [:contributor],
      work: [series_memberships: [:series], contributions: [:contributor]]
    ])
    |> Ash.read!()
    |> Enum.map(&edition_projection/1)
    |> attach_sources()
    |> Enum.sort_by(&sort_key/1)
  end

  def search_editions(query) do
    editions()
    |> Enum.filter(&matches?(&1, query))
  end

  def paginate(items, page, page_size \\ @page_size) do
    total_count = length(items)
    total_pages = max(ceil_div(max(total_count, 1), page_size), 1)
    current_page = page |> parse_page() |> min(total_pages) |> max(1)

    %{
      entries: Enum.slice(items, (current_page - 1) * page_size, page_size),
      page: current_page,
      page_size: page_size,
      total_count: total_count,
      total_pages: total_pages
    }
  end

  def publishers do
    editions = editions()

    Publisher
    |> Ash.Query.for_read(:read)
    |> Ash.read!()
    |> Enum.map(fn publisher ->
      publisher_editions = Enum.filter(editions, &(&1.publisher_slug == publisher.slug))

      %{
        id: publisher.id,
        name: publisher.name,
        slug: publisher.slug,
        description: publisher.description,
        editions: publisher_editions,
        editions_count: length(publisher_editions)
      }
    end)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  def publisher(slug) do
    Enum.find(publishers(), &(&1.slug == slug))
  end

  def series do
    editions = editions()

    Series
    |> Ash.Query.for_read(:read)
    |> Ash.Query.load([:publisher, :series_memberships])
    |> Ash.read!()
    |> Enum.map(fn series ->
      memberships = loaded_list(series.series_memberships)
      work_ids = Enum.map(memberships, & &1.work_id)

      series_editions =
        editions
        |> Enum.filter(&(&1.work_id in work_ids))
        |> Enum.sort_by(fn edition ->
          membership = Enum.find(memberships, &(&1.work_id == edition.work_id))

          {is_nil(membership && membership.position), (membership && membership.position) || 0,
           edition.title}
        end)

      publisher = loaded_or_nil(series.publisher)

      %{
        id: series.id,
        title: series.title,
        name: series.title,
        slug: series.slug,
        publisher: publisher && publisher.name,
        publisher_slug: publisher && publisher.slug,
        editions: series_editions,
        editions_count: length(series_editions),
        unknown_order?: Enum.any?(memberships, &is_nil(&1.position))
      }
    end)
    |> Enum.sort_by(&String.downcase(&1.title))
  end

  def series_by_slug(slug) do
    Enum.find(series(), &(&1.slug == slug))
  end

  def edition(slug) do
    Enum.find(editions(), &(&1.slug == slug))
  end

  defp edition_projection(edition) do
    publisher = loaded_or_nil(edition.publisher)
    work = loaded_or_nil(edition.work)
    contributions = loaded_list(edition.contributions) ++ loaded_list(work && work.contributions)
    identifiers = loaded_list(edition.identifiers)
    cover_assignment = visible_cover_assignment(edition)
    cover_asset = cover_assignment && loaded_or_nil(cover_assignment.cover_asset)

    series_memberships = loaded_list(work && work.series_memberships)

    %{
      id: edition.id,
      work_id: edition.work_id,
      title: edition.title,
      subtitle: edition.subtitle,
      slug: edition.slug,
      format: edition.format,
      published_on: edition.published_on,
      year: edition.published_on && edition.published_on.year,
      publisher: publisher && publisher.name,
      publisher_slug: publisher && publisher.slug,
      author: contributor_text(contributions),
      contributor_names: contributor_names(contributions),
      identifiers: identifier_values(identifiers),
      isbn: first_identifier(identifiers),
      series_titles: series_titles(series_memberships),
      series_slug: first_series_slug(series_memberships),
      cover: cover_projection(cover_asset),
      source: nil,
      source_uri: "local_demo_fixture:edition:#{edition.slug}",
      source_uri_candidates: [
        "local_demo_fixture:edition:#{edition.slug}",
        "local_csv_import:edition:#{edition.slug}"
      ]
    }
  end

  defp attach_sources(editions) do
    source_records =
      SourceRecord
      |> Ash.Query.for_read(:read)
      |> Ash.read!()

    source_by_uri = Map.new(source_records, &{&1.source_uri, source_projection(&1)})
    source_by_isbn = source_by_isbn(source_records)

    editions
    |> Enum.map(fn edition ->
      source =
        edition
        |> Map.fetch!(:source_uri_candidates)
        |> Enum.find_value(&Map.get(source_by_uri, &1)) ||
          edition.identifiers
          |> Enum.find_value(&Map.get(source_by_isbn, &1))

      edition
      |> Map.put(:source, source)
      |> Map.put(:source_uri, source && source.source_uri)
      |> Map.delete(:source_uri_candidates)
    end)
    |> Enum.reject(&is_nil(&1.source))
  end

  defp source_by_isbn(source_records) do
    source_records
    |> Enum.flat_map(fn source_record ->
      isbn = get_in(source_record.raw_payload || %{}, ["edition", "isbn_13"])
      if is_binary(isbn), do: [{isbn, source_projection(source_record)}], else: []
    end)
    |> Map.new()
  end

  defp source_projection(source_record) do
    %{
      provider: source_record.provider,
      source_type: source_record.source_type,
      source_uri: source_record.source_uri,
      license_note: source_record.license_note,
      imported_at: source_record.imported_at
    }
  end

  defp visible_cover_assignment(edition) do
    edition.cover_assignments
    |> loaded_list()
    |> Enum.filter(fn assignment ->
      asset = loaded_or_nil(assignment.cover_asset)

      assignment.visible? and Covers.public_cover_asset?(asset)
    end)
    |> Enum.sort_by(&{&1.position || 0, &1.id})
    |> List.first()
  end

  defp cover_projection(nil), do: nil

  defp cover_projection(asset) do
    %{
      source_url: asset.source_url,
      provider: asset.provider,
      rights_basis: asset.rights_basis,
      attribution_text: asset.attribution_text,
      attribution_url: asset.attribution_url,
      cache_policy: asset.cache_policy,
      takedown_state: asset.takedown_state
    }
  end

  defp contributor_names(contributions) do
    contributions
    |> Enum.sort_by(&{&1.position || 0, &1.role, &1.id})
    |> Enum.map(&loaded_or_nil(&1.contributor))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.display_name)
    |> Enum.uniq()
  end

  defp contributor_text(contributions) do
    case contributor_names(contributions) do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end

  defp identifier_values(identifiers) do
    identifiers
    |> Enum.sort_by(&{&1.identifier_type, &1.value})
    |> Enum.map(& &1.value)
  end

  defp first_identifier(identifiers), do: identifiers |> identifier_values() |> List.first()

  defp series_titles(series_memberships) do
    series_memberships
    |> Enum.sort_by(&{&1.position || 0, &1.id})
    |> Enum.map(&loaded_or_nil(&1.series))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.title)
    |> Enum.uniq()
  end

  defp first_series_slug(series_memberships) do
    series_memberships
    |> Enum.sort_by(&{&1.position || 0, &1.id})
    |> Enum.map(&loaded_or_nil(&1.series))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.slug)
    |> List.first()
  end

  defp matches?(_edition, nil), do: true
  defp matches?(_edition, ""), do: true

  defp matches?(edition, query) do
    needle = normalize_text(query)
    identifier_needle = normalize_identifier(query)

    searchable_text =
      [
        edition.title,
        edition.subtitle,
        edition.publisher,
        edition.author,
        edition.series_titles,
        edition.identifiers
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &to_string/1)
      |> normalize_text()

    searchable_identifiers = Enum.map_join(edition.identifiers, " ", &normalize_identifier/1)

    String.contains?(searchable_text, needle) or
      (identifier_needle != "" and String.contains?(searchable_identifiers, identifier_needle))
  end

  defp sort_key(edition),
    do: {demo_fixture_order(edition.slug), String.downcase(edition.title), edition.slug}

  defp demo_fixture_order("the-orchard-of-minor-moons-paperback"), do: 0
  defp demo_fixture_order("index-of-borrowed-harbors-first"), do: 1
  defp demo_fixture_order("rooms-for-unwritten-letters-classic"), do: 2
  defp demo_fixture_order(_slug), do: 100

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp parse_page(page) when is_integer(page), do: page

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} -> page
      _ -> 1
    end
  end

  defp parse_page(_page), do: 1

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
