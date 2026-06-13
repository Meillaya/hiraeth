defmodule HiraethWeb.PublicCatalog do
  @moduledoc """
  Ash-backed read model for public LiveView catalog pages.

  The module deliberately projects only known persisted fields. It never fills in
  unknown dates, languages, dimensions, page counts, translators, or cover art.
  """

  require Ash.Query

  alias Hiraeth.Catalog.{Publisher, Series}
  alias Hiraeth.RealCatalog.SourcePolicy

  @page_size 24

  def page_size, do: @page_size

  def books do
    book_page(nil, 1).entries
  end

  def search_books(query) do
    book_page(query, 1).entries
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
    edition_rows("where e.work_id = any($1::uuid[])", [work_ids])
    |> Enum.map(&edition_projection_from_row/1)
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

  defp count_books_for_query(query) when query in [nil, ""] do
    {:ok, %{rows: [[count]]}} =
      Hiraeth.Repo.query(
        """
        select count(distinct e.work_id)
        from editions e
        join identifiers source_identifier on source_identifier.edition_id = e.id
        join source_records sr
          on coalesce(sr.raw_payload->'edition'->>'isbn_13', sr.raw_payload->'identifier'->>'isbn_13') = source_identifier.value
        """,
        []
      )

    count
  end

  defp count_books_for_query(query) do
    {where, params} = work_query_where(query)

    {:ok, %{rows: [[count]]}} =
      Hiraeth.Repo.query(
        """
        select count(distinct e.work_id)
        from editions e
        join works w on w.id = e.work_id
        join identifiers source_identifier on source_identifier.edition_id = e.id
        join source_records sr
          on coalesce(sr.raw_payload->'edition'->>'isbn_13', sr.raw_payload->'identifier'->>'isbn_13') = source_identifier.value
        left join publishers p on p.id = e.publisher_id
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

  defp work_ids_for_query(query, limit, offset) when query in [nil, ""] do
    {limit_sql, params} = limit_params(limit, offset, [])

    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select e.work_id
        from editions e
        join works w on w.id = e.work_id
        join identifiers source_identifier on source_identifier.edition_id = e.id
        join source_records sr
          on coalesce(sr.raw_payload->'edition'->>'isbn_13', sr.raw_payload->'identifier'->>'isbn_13') = source_identifier.value
        group by e.work_id, w.title
        order by lower(w.title), min(e.slug)
        #{limit_sql}
        """,
        params
      )

    Enum.map(rows, fn [work_id] -> work_id end)
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
        join identifiers source_identifier on source_identifier.edition_id = e.id
        join source_records sr
          on coalesce(sr.raw_payload->'edition'->>'isbn_13', sr.raw_payload->'identifier'->>'isbn_13') = source_identifier.value
        left join publishers p on p.id = e.publisher_id
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

  defp work_query_where(query) do
    needle = "%#{like_escape(normalize_text(query))}%"
    normalized_identifier = normalize_identifier(query)
    identifier = if normalized_identifier == "", do: "", else: "%#{normalized_identifier}%"

    {
      """
      where lower(coalesce(w.title, '')) like $1 escape '!'
         or lower(coalesce(w.subtitle, '')) like $1 escape '!'
         or lower(coalesce(e.title, '')) like $1 escape '!'
         or lower(coalesce(e.subtitle, '')) like $1 escape '!'
         or lower(coalesce(p.name, '')) like $1 escape '!'
         or lower(coalesce(ct.display_name, '')) like $1 escape '!'
         or lower(coalesce(s.title, '')) like $1 escape '!'
         or ($2 <> '' and regexp_replace(coalesce(source_identifier.value, ''), '[^0-9xX]', '', 'g') like $2)
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
    edition_rows("", [])
    |> Enum.map(&edition_projection_from_row/1)
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

  defp edition_rows(where_sql, params) do
    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select
          e.id,
          e.work_id,
          e.title,
          e.subtitle,
          e.slug,
          e.format,
          e.published_on,
          p.name,
          p.slug,
          w.description,
          w.editorial_praise,
          w.storefront_url,
          coalesce(identifiers.data, '[]'::jsonb),
          coalesce(contributors.data, '[]'::jsonb),
          coalesce(series.data, '[]'::jsonb),
          coalesce(covers.data, '[]'::jsonb),
          source.data
        from editions e
        join works w on w.id = e.work_id
        join publishers p on p.id = e.publisher_id
        join lateral (
          select jsonb_agg(i.value order by i.identifier_type, i.value) as data
          from identifiers i
          where i.edition_id = e.id
        ) identifiers on true
        join lateral (
          select jsonb_build_object(
            'id', sr.id,
            'source_record_id', sr.id,
            'provider', sr.provider,
            'source_type', sr.source_type,
            'source_uri', sr.source_uri,
            'license_note', sr.license_note,
            'import_run_id', sr.import_run_id,
            'imported_at', sr.imported_at
          ) as data
          from identifiers source_identifier
          join source_records sr
            on coalesce(sr.raw_payload->'edition'->>'isbn_13', sr.raw_payload->'identifier'->>'isbn_13') = source_identifier.value
          where source_identifier.edition_id = e.id
          order by sr.imported_at desc nulls last, sr.id
          limit 1
        ) source on true
        left join lateral (
          select jsonb_agg(
            jsonb_build_object(
              'id', c.id,
              'position', c.position,
              'role', c.role,
              'name', ct.display_name
            )
            order by coalesce(c.position, 0), c.role, c.id
          ) as data
          from contributions c
          join contributors ct on ct.id = c.contributor_id
          where c.work_id = e.work_id or c.edition_id = e.id
        ) contributors on true
        left join lateral (
          select jsonb_agg(
            jsonb_build_object(
              'id', sm.id,
              'position', sm.position,
              'title', s.title,
              'slug', s.slug
            )
            order by coalesce(sm.position, 0), sm.id
          ) as data
          from series_memberships sm
          join series s on s.id = sm.series_id
          where sm.work_id = e.work_id
        ) series on true
        left join lateral (
          select jsonb_agg(
            jsonb_build_object(
              'id', ca.id,
              'position', ca.position,
              'visible?', ca."visible?",
              'source_url', cover.source_url,
              'provider', cover.provider,
              'rights_basis', cover.rights_basis,
              'attribution_text', cover.attribution_text,
              'attribution_url', cover.attribution_url,
              'cache_policy', cover.cache_policy,
              'cached_file_path', cover.cached_file_path,
              'takedown_state', cover.takedown_state
            )
            order by coalesce(ca.position, 0), ca.id
          ) as data
          from cover_assignments ca
          join cover_assets cover on cover.id = ca.cover_asset_id
          where ca.edition_id = e.id
        ) covers on true
        #{where_sql}
        """,
        params
      )

    rows
  end

  defp edition_projection_from_row([
         id,
         work_id,
         title,
         subtitle,
         slug,
         format,
         published_on,
         publisher,
         publisher_slug,
         description,
         editorial_praise,
         storefront_url,
         identifiers,
         contributors,
         series,
         covers,
         source
       ]) do
    identifiers = Enum.sort(identifiers || [])
    contributors = contributors || []
    series = series || []
    cover = covers |> public_cover_data() |> cover_projection_from_data()

    %{
      id: id,
      work_id: work_id,
      title: title,
      subtitle: subtitle,
      slug: slug,
      format: format,
      published_on: published_on,
      year: published_on && published_on.year,
      publisher: publisher,
      publisher_slug: publisher_slug,
      author: contributor_text_from_data(contributors),
      contributor_names: contributor_names_from_data(contributors),
      identifiers: identifiers,
      isbn: List.first(identifiers),
      series_titles: series_titles_from_data(series),
      series_slug: first_series_slug_from_data(series),
      cover: cover,
      description: description,
      editorial_praise: editorial_praise || [],
      storefront_url: storefront_url,
      source: atomize_source(source),
      source_uri: source && source["source_uri"]
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

  defp cover_projection_from_data(nil), do: nil

  defp cover_projection_from_data(asset) do
    %{
      source_url: asset["source_url"],
      public_url: cover_public_url_from_data(asset),
      provider: asset["provider"],
      rights_basis: asset["rights_basis"],
      attribution_text: asset["attribution_text"],
      attribution_url: asset["attribution_url"],
      cache_policy: asset["cache_policy"],
      takedown_state: asset["takedown_state"]
    }
  end

  defp cover_public_url_from_data(%{
         "cache_policy" => "cache_allowed",
         "cached_file_path" => path
       })
       when is_binary(path) do
    static_cover_path(path) || path
  end

  defp cover_public_url_from_data(asset), do: asset["source_url"]

  defp public_cover_data(covers) do
    covers
    |> Enum.filter(&public_cover_data?/1)
    |> Enum.sort_by(&{&1["position"] || 0, &1["id"]})
    |> List.first()
  end

  defp public_cover_data?(asset) do
    uri = parse_uri(asset["source_url"])

    truthy?(asset["visible?"]) and asset["takedown_state"] == "visible" and
      present?(asset["source_url"]) and present?(asset["provider"]) and
      present?(asset["rights_basis"]) and uri.scheme == "https" and
      SourcePolicy.cover_host_allowed?(asset["provider"], uri.host) and
      public_cache_policy_data?(asset)
  end

  defp public_cache_policy_data?(%{"cache_policy" => "link_only", "cached_file_path" => path}) do
    not present?(path)
  end

  defp public_cache_policy_data?(%{
         "cache_policy" => "cache_allowed",
         "rights_basis" => "local_cache_permitted",
         "cached_file_path" => path
       }) do
    safe_cached_file_path?(path)
  end

  defp public_cache_policy_data?(_asset), do: false

  defp static_cover_path(path) when is_binary(path) do
    path = Path.expand(path)
    static_root = Path.expand("priv/static")

    if String.starts_with?(path, static_root <> "/") do
      "/" <> Path.relative_to(path, static_root)
    end
  end

  defp static_cover_path(_path), do: nil

  defp contributor_names_from_data(contributors) do
    contributors
    |> Enum.sort_by(&{&1["position"] || 0, &1["role"], &1["id"]})
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp contributor_text_from_data(contributors) do
    case contributor_names_from_data(contributors) do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end

  defp series_titles_from_data(series) do
    series
    |> Enum.sort_by(&{&1["position"] || 0, &1["id"]})
    |> Enum.map(& &1["title"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp first_series_slug_from_data(series) do
    series
    |> Enum.sort_by(&{&1["position"] || 0, &1["id"]})
    |> Enum.map(& &1["slug"])
    |> Enum.reject(&is_nil/1)
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

  defp atomize_source(nil), do: nil

  defp atomize_source(source) do
    %{
      id: source["id"],
      source_record_id: source["source_record_id"],
      provider: source["provider"],
      source_type: source["source_type"],
      source_uri: source["source_uri"],
      license_note: source["license_note"],
      import_run_id: source["import_run_id"],
      imported_at: parse_imported_at(source["imported_at"])
    }
  end

  defp parse_imported_at(%DateTime{} = value), do: value
  defp parse_imported_at(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp parse_imported_at(value) when is_binary(value) do
    with {:error, _reason} <- DateTime.from_iso8601(value),
         {:ok, naive} <- NaiveDateTime.from_iso8601(value) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_imported_at(_value), do: nil

  defp safe_cached_file_path?(path) when is_binary(path) do
    path = Path.expand(path)
    cache_root = Path.expand("priv/static/covers/cache")

    String.starts_with?(path, cache_root <> "/") and File.exists?(path)
  end

  defp safe_cached_file_path?(_path), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp parse_uri(value) when is_binary(value), do: URI.parse(value)
  defp parse_uri(_value), do: %URI{}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

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

  defp like_escape(value) do
    value
    |> String.replace("!", "!!")
    |> String.replace("%", "!%")
    |> String.replace("_", "!_")
  end

  defp normalize_identifier(value) do
    value
    |> to_string()
    |> String.replace(~r/[^0-9xX]/, "")
    |> String.downcase()
  end
end
