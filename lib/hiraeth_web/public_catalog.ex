defmodule HiraethWeb.PublicCatalog do
  @moduledoc """
  Ash-backed read model for public LiveView catalog pages.

  The module deliberately projects only known persisted fields. It never fills in
  unknown dates, languages, dimensions, page counts, translators, or cover art.
  """

  import Ash.Expr
  require Ash.Query

  alias Hiraeth.Catalog.{Edition, Publisher, Series}
  alias Hiraeth.Covers

  @page_size 24

  def page_size, do: @page_size

  def books do
    books_for_query(nil, :all, 0)
  end

  def search_books(query) do
    books_for_query(query, :all, 0)
  end

  def book_page(query, page, page_size \\ @page_size) do
    total_count = count_books_for_query(query)
    total_pages = max(ceil_div(max(total_count, 1), page_size), 1)
    current_page = page |> parse_page() |> min(total_pages) |> max(1)

    %{
      entries: books_for_query(query, page_size, (current_page - 1) * page_size),
      page: current_page,
      page_size: page_size,
      total_count: total_count,
      total_pages: total_pages
    }
  end

  def book(slug) do
    case work_id_for_slug(slug) do
      nil ->
        nil

      work_id ->
        Enum.find(
          books_for_work_ids([work_id]),
          &(&1.slug == slug or Enum.any?(&1.formats, fn format -> format.edition_slug == slug end))
        )
    end
  end

  defp books_for_query(query, limit, offset) do
    query
    |> work_ids_for_query(limit, offset)
    |> books_for_work_ids()
  end

  defp books_for_work_ids([]), do: []

  defp books_for_work_ids(work_ids) do
    work_order = work_ids |> Enum.with_index() |> Map.new()

    work_ids
    |> editions_for_work_ids()
    |> Enum.group_by(& &1.work_id)
    |> Enum.map(fn {_work_id, editions} -> book_projection(editions) end)
    |> Enum.sort_by(fn book -> Map.get(work_order, book.work_id, 999_999) end)
  end

  defp editions_for_work_ids(work_ids) do
    Edition
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(expr(work_id in ^work_ids))
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
  end

  defp work_id_for_slug(slug) do
    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select e.work_id
        from editions e
        join works w on w.id = e.work_id
        where e.slug = $1 or w.slug = $1 or regexp_replace(e.slug, '-(paperback|hardcover|ebook|audiobook)-[0-9xX-]+$', '') = $1
        limit 1
        """,
        [slug]
      )

    case rows do
      [[work_id]] -> work_id
      _rows -> nil
    end
  end

  defp count_books_for_query(query) do
    {where, params} = work_query_where(query)

    {:ok, %{rows: [[count]]}} =
      Hiraeth.Repo.query(
        """
        select count(distinct e.work_id)
        from editions e
        join works w on w.id = e.work_id
        left join publishers p on p.id = e.publisher_id
        left join identifiers i on i.edition_id = e.id
        left join contributions c on c.work_id = w.id or c.edition_id = e.id
        left join contributors ct on ct.id = c.contributor_id
        left join series_memberships sm on sm.work_id = w.id
        left join series s on s.id = sm.series_id
        #{where}
        """,
        params
      )

    count
  end

  defp work_ids_for_query(query, limit, offset) do
    {where, params} = work_query_where(query)
    {limit_sql, params} = limit_params(limit, offset, params)

    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select e.work_id
        from editions e
        join works w on w.id = e.work_id
        left join publishers p on p.id = e.publisher_id
        left join identifiers i on i.edition_id = e.id
        left join contributions c on c.work_id = w.id or c.edition_id = e.id
        left join contributors ct on ct.id = c.contributor_id
        left join series_memberships sm on sm.work_id = w.id
        left join series s on s.id = sm.series_id
        #{where}
        group by e.work_id, w.title
        order by lower(w.title), min(e.slug)
        #{limit_sql}
        """,
        params
      )

    Enum.map(rows, fn [work_id] -> work_id end)
  end

  defp work_query_where(query) when query in [nil, ""], do: {"", []}

  defp work_query_where(query) do
    needle = "%#{normalize_text(query)}%"
    normalized_identifier = normalize_identifier(query)
    identifier = if normalized_identifier == "", do: "", else: "%#{normalized_identifier}%"

    {
      """
      where lower(coalesce(w.title, '')) like $1
         or lower(coalesce(w.subtitle, '')) like $1
         or lower(coalesce(e.title, '')) like $1
         or lower(coalesce(e.subtitle, '')) like $1
         or lower(coalesce(p.name, '')) like $1
         or lower(coalesce(ct.display_name, '')) like $1
         or lower(coalesce(s.title, '')) like $1
         or ($2 <> '' and regexp_replace(coalesce(i.value, ''), '[^0-9xX]', '', 'g') like $2)
      """,
      [needle, identifier]
    }
  end

  defp limit_params(:all, _offset, params), do: {"", params}

  defp limit_params(limit, offset, params) do
    limit_index = length(params) + 1
    offset_index = length(params) + 2
    {"limit $#{limit_index} offset $#{offset_index}", params ++ [limit, offset]}
  end

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
      description: work && work.description,
      editorial_praise: (work && work.editorial_praise) || [],
      storefront_url: work && work.storefront_url,
      source: nil,
      source_uri: nil
    }
  end

  defp book_projection(editions) do
    editions = Enum.sort_by(editions, &format_sort_key/1)
    primary = List.first(editions)

    %{}
    |> Map.merge(
      Map.take(primary, [
        :work_id,
        :title,
        :subtitle,
        :publisher,
        :publisher_slug,
        :author,
        :contributor_names,
        :series_titles,
        :series_slug,
        :cover,
        :source
      ])
    )
    |> Map.put(:id, primary.work_id)
    |> Map.put(:slug, work_slug(primary))
    |> Map.put(:description, first_present(editions, :description))
    |> Map.put(:editorial_praise, first_present(editions, :editorial_praise) || [])
    |> Map.put(:praise, first_present(editions, :editorial_praise) || [])
    |> Map.put(:storefront_url, first_present(editions, :storefront_url))
    |> Map.put(:formats, Enum.map(editions, &format_projection/1))
    |> Map.put(
      :identifiers,
      editions |> Enum.flat_map(& &1.identifiers) |> Enum.uniq() |> Enum.sort()
    )
    |> Map.put(:isbn, editions |> Enum.flat_map(& &1.identifiers) |> Enum.uniq() |> List.first())
    |> Map.put(:sources, editions |> Enum.map(& &1.source) |> Enum.reject(&is_nil/1))
    |> Map.put(:published_on, first_present(editions, :published_on))
    |> Map.put(:year, primary.year)
  end

  defp format_projection(edition) do
    %{
      edition_slug: edition.slug,
      format: edition.format,
      format_label: format_label(edition.format),
      identifiers: edition.identifiers,
      published_on: edition.published_on
    }
  end

  defp first_present(editions, key) do
    editions
    |> Enum.map(&Map.get(&1, key))
    |> Enum.find(&(not blank?(&1)))
  end

  defp work_slug(edition) do
    edition.slug
    |> String.replace(~r/-(paperback|hardcover|ebook|audiobook)-[0-9xX-]+$/, "")
  end

  defp format_label(nil), do: "Unknown format"

  defp format_label(format) do
    format
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_sort_key(edition),
    do: {format_rank(edition.format), edition.published_on || ~D[9999-12-31], edition.slug}

  defp format_rank("paperback"), do: 0
  defp format_rank("hardcover"), do: 1
  defp format_rank("ebook"), do: 2
  defp format_rank("audiobook"), do: 3
  defp format_rank(_format), do: 9

  defp attach_sources(editions) do
    source_by_isbn =
      editions
      |> Enum.flat_map(& &1.identifiers)
      |> Enum.uniq()
      |> source_by_isbn()

    editions
    |> Enum.map(fn edition ->
      source = Enum.find_value(edition.identifiers, &Map.get(source_by_isbn, &1))

      edition
      |> Map.put(:source, source)
      |> Map.put(:source_uri, source && source.source_uri)
    end)
    |> Enum.reject(&is_nil(&1.source))
  end

  defp source_by_isbn([]), do: %{}

  defp source_by_isbn(isbns) do
    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select id, provider, source_type, source_uri, license_note, import_run_id, imported_at, raw_payload,
               coalesce(raw_payload->'edition'->>'isbn_13', raw_payload->'identifier'->>'isbn_13') as isbn
        from source_records
        where coalesce(raw_payload->'edition'->>'isbn_13', raw_payload->'identifier'->>'isbn_13') = any($1::text[])
        """,
        [isbns]
      )

    rows
    |> Enum.map(fn [
                     id,
                     provider,
                     source_type,
                     source_uri,
                     license_note,
                     import_run_id,
                     imported_at,
                     raw_payload,
                     isbn
                   ] ->
      isbn =
        isbn || get_in(raw_payload || %{}, ["edition", "isbn_13"]) ||
          get_in(raw_payload || %{}, ["identifier", "isbn_13"])

      {isbn,
       %{
         id: id,
         source_record_id: id,
         provider: provider,
         source_type: source_type,
         source_uri: source_uri,
         license_note: license_note,
         import_run_id: import_run_id,
         imported_at: imported_at
       }}
    end)
    |> Enum.reject(fn {isbn, _source} -> is_nil(isbn) end)
    |> Map.new()
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
      public_url: cover_public_url(asset),
      provider: asset.provider,
      rights_basis: asset.rights_basis,
      attribution_text: asset.attribution_text,
      attribution_url: asset.attribution_url,
      cache_policy: asset.cache_policy,
      takedown_state: asset.takedown_state
    }
  end

  defp cover_public_url(asset) do
    case asset.cache_policy do
      "cache_allowed" -> static_cover_path(asset.cached_file_path) || asset.source_url
      _ -> asset.source_url
    end
  end

  defp static_cover_path(path) when is_binary(path) do
    path = Path.expand(path)
    static_root = Path.expand("priv/static")

    if String.starts_with?(path, static_root <> "/") do
      "/" <> Path.relative_to(path, static_root)
    end
  end

  defp static_cover_path(_path), do: nil

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

  defp blank?(value), do: value in [nil, [], ""]

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
