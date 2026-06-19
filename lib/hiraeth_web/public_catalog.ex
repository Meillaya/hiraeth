defmodule HiraethWeb.PublicCatalog do
  @moduledoc """
  Ash-backed read model for public LiveView catalog pages.

  The module deliberately projects only known persisted fields. It never fills in
  unknown dates, languages, dimensions, page counts, or cover art.
  """

  alias Hiraeth.RealCatalog.SourcePolicy

  @page_size 24
  @publisher_group_limit 8
  @cache_missing :__hiraeth_public_catalog_cache_missing__
  @default_cache_ttl_ms :timer.seconds(30)
  @undated_sort_value Date.to_gregorian_days(~D[0001-01-01])

  def page_size, do: @page_size

  def books do
    book_page(nil, 1).entries
  end

  def search_books(query) do
    book_page(query, 1).entries
  end

  def book_page(query, page, page_size \\ @page_size) do
    filters = normalize_book_filters(query)
    requested_page = page |> parse_page() |> max(1)
    requested_offset = (requested_page - 1) * page_size
    {total_count, work_ids} = work_page_for_filters(filters, page_size, requested_offset)

    total_count =
      if work_ids == [] and requested_page > 1 do
        count_books_for_filters(filters)
      else
        total_count
      end

    total_pages = max(ceil_div(max(total_count, 1), page_size), 1)
    current_page = min(requested_page, total_pages)

    work_ids =
      if current_page == requested_page do
        work_ids
      else
        {_total_count, work_ids} =
          work_page_for_filters(filters, page_size, (current_page - 1) * page_size)

        work_ids
      end

    %{
      entries: books_for_work_ids(work_ids),
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

  defp books_for_work_ids([]), do: []

  defp books_for_work_ids(work_ids) do
    work_order =
      work_ids
      |> Enum.map(&uuid_text/1)
      |> Enum.with_index()
      |> Map.new()

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

  defp books_for_publisher_id(publisher_id) do
    edition_rows("where e.publisher_id = $1::uuid", [uuid_param(publisher_id)])
    |> Enum.map(&edition_projection_from_row/1)
    |> Enum.group_by(& &1.work_id)
    |> Enum.map(fn {_work_id, editions} -> book_projection(editions) end)
    |> Enum.sort_by(&publication_date_sort_key/1)
  end

  defp work_id_for_slug(slug) do
    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select e.work_id
        from editions e
        join works w on w.id = e.work_id
        where (
            e.slug = $1
            or w.slug = $1
            or regexp_replace(e.slug, '-(paperback|hardcover|ebook|audiobook)-[0-9xX-]+$', '') = $1
          )
          and exists (
            select 1
            from source_records sr
            where sr.edition_id = e.id
          )
        limit 1
        """,
        [slug]
      )

    case rows do
      [[work_id]] -> work_id
      _rows -> nil
    end
  end

  defp count_books_for_filters(filters) do
    if default_title_page_filters?(filters) do
      count_default_title_books()
    else
      count_filtered_books(filters)
    end
  end

  defp count_default_title_books do
    {:ok, %{rows: [[count]]}} =
      Hiraeth.Repo.query(
        """
        select count(distinct e.work_id)
        from editions e
        join works w on w.id = e.work_id
        join source_records sr on sr.edition_id = e.id
        """,
        []
      )

    count
  end

  defp count_filtered_books(filters) do
    {where, params} = work_filter_where(filters)

    {:ok, %{rows: [[count]]}} =
      Hiraeth.Repo.query(
        """
        select count(distinct e.work_id)
        from editions e
        join works w on w.id = e.work_id
        join source_records sr on sr.edition_id = e.id
        left join identifiers display_identifier
          on display_identifier.edition_id = e.id and display_identifier.identifier_type = 'isbn_13'
        left join publishers p on p.id = e.publisher_id
        #{where}
        """,
        params
      )

    count
  end

  defp work_page_for_filters(filters, limit, offset) do
    if default_title_page_filters?(filters) do
      default_title_work_page(limit, offset)
    else
      filtered_work_page(filters, limit, offset)
    end
  end

  defp default_title_work_page(limit, offset) do
    {limit_sql, params} = limit_params(limit, offset, [])

    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select work_id, count(*) over() as total_count
        from (
          select
            e.work_id,
            lower(w.title) as title_sort,
            min(e.slug) as slug_sort,
            max(e.published_on) as newest_sort
          from editions e
          join works w on w.id = e.work_id
          join source_records sr on sr.edition_id = e.id
          group by e.work_id, w.title
        ) grouped_books
        order by #{publication_date_order_sql()}
        #{limit_sql}
        """,
        params
      )

    work_page_from_rows(rows)
  end

  defp filtered_work_page(filters, limit, offset) do
    {where, params} = work_filter_where(filters)
    {limit_sql, params} = limit_params(limit, offset, params)
    order_sql = work_page_order_sql(filters.sort)

    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select work_id, count(*) over() as total_count
        from (
          select
            e.work_id,
            lower(w.title) as title_sort,
            min(e.slug) as slug_sort,
            max(e.published_on) as newest_sort,
            max(sr.imported_at) as imported_sort
          from editions e
          join works w on w.id = e.work_id
          join source_records sr on sr.edition_id = e.id
          left join identifiers display_identifier
            on display_identifier.edition_id = e.id and display_identifier.identifier_type = 'isbn_13'
          left join publishers p on p.id = e.publisher_id
          #{where}
          group by e.work_id, w.title
        ) grouped_books
        order by #{order_sql}
        #{limit_sql}
        """,
        params
      )

    work_page_from_rows(rows)
  end

  defp work_page_from_rows([]), do: {0, []}

  defp work_page_from_rows(rows) do
    total_count = rows |> List.first() |> List.last()
    work_ids = Enum.map(rows, fn [work_id, _total_count] -> work_id end)

    {total_count, work_ids}
  end

  defp work_filter_where(filters) do
    {conditions, params} =
      {[], []}
      |> add_text_filter(filters.q)
      |> add_slug_or_name_filter(filters.publisher, "p.slug", "p.name")
      |> add_role_filter(filters.role)
      |> add_contributor_filter(filters.contributor)
      |> add_exact_filter(filters.format, "lower(coalesce(e.format, ''))")
      |> add_language_filter(filters.language)
      |> add_subject_filter(filters.subject)
      |> add_series_filter(filters.series)
      |> add_year_filter(filters.year)

    case conditions do
      [] -> {"", params}
      _ -> {"where " <> Enum.join(Enum.reverse(conditions), " and "), params}
    end
  end

  defp add_text_filter({conditions, params}, value) when value in [nil, ""],
    do: {conditions, params}

  defp add_text_filter({conditions, params}, value) do
    needle = "%#{like_escape(normalize_text(value))}%"
    normalized_identifier = normalize_identifier(value)
    identifier = if normalized_identifier == "", do: "", else: "%#{normalized_identifier}%"
    text_index = length(params) + 1
    identifier_index = length(params) + 2

    condition =
      """
      (lower(coalesce(w.title, '')) like $#{text_index} escape '!'
         or lower(coalesce(w.subtitle, '')) like $#{text_index} escape '!'
         or lower(coalesce(e.title, '')) like $#{text_index} escape '!'
         or lower(coalesce(e.subtitle, '')) like $#{text_index} escape '!'
         or lower(coalesce(p.name, '')) like $#{text_index} escape '!'
         or exists (
           select 1
           from contributions c
           join contributors ct on ct.id = c.contributor_id
           where (c.work_id = w.id or c.edition_id = e.id)
             and lower(coalesce(ct.display_name, '')) like $#{text_index} escape '!'
         )
         or exists (
           select 1
           from series_memberships sm
           join series s on s.id = sm.series_id
           where sm.work_id = w.id
             and lower(coalesce(s.title, '')) like $#{text_index} escape '!'
         )
         or ($#{identifier_index} <> '' and regexp_replace(coalesce(display_identifier.value, ''), '[^0-9xX]', '', 'g') like $#{identifier_index}))
      """

    {[condition | conditions], params ++ [needle, identifier]}
  end

  defp add_slug_or_name_filter({conditions, params}, value, _slug_column, _name_column)
       when value in [nil, ""] do
    {conditions, params}
  end

  defp add_slug_or_name_filter({conditions, params}, value, slug_column, name_column) do
    exact = normalize_text(value)
    like = "%#{like_escape(exact)}%"
    exact_index = length(params) + 1
    like_index = length(params) + 2

    condition =
      "(lower(coalesce(#{slug_column}, '')) = $#{exact_index} or lower(coalesce(#{name_column}, '')) like $#{like_index} escape '!')"

    {[condition | conditions], params ++ [exact, like]}
  end

  defp add_exact_filter({conditions, params}, value, _expression) when value in [nil, ""] do
    {conditions, params}
  end

  defp add_exact_filter({conditions, params}, value, expression) do
    index = length(params) + 1
    {["#{expression} = $#{index}" | conditions], params ++ [normalize_text(value)]}
  end

  defp add_role_filter({conditions, params}, value) when value in [nil, ""],
    do: {conditions, params}

  defp add_role_filter({conditions, params}, value) do
    index = length(params) + 1

    condition =
      """
      exists (
        select 1
        from contributions c
        where (c.work_id = w.id or c.edition_id = e.id)
          and c.role = $#{index}
      )
      """

    {[condition | conditions], params ++ [normalize_text(value)]}
  end

  defp add_contributor_filter({conditions, params}, value) when value in [nil, ""],
    do: {conditions, params}

  defp add_contributor_filter({conditions, params}, value) do
    exact = normalize_text(value)
    like = "%#{like_escape(exact)}%"
    exact_index = length(params) + 1
    like_index = length(params) + 2

    condition =
      """
      exists (
        select 1
        from contributions c
        join contributors ct on ct.id = c.contributor_id
        where (c.work_id = w.id or c.edition_id = e.id)
          and (
            lower(coalesce(ct.slug, '')) = $#{exact_index}
            or lower(coalesce(ct.display_name, '')) like $#{like_index} escape '!'
          )
      )
      """

    {[condition | conditions], params ++ [exact, like]}
  end

  defp add_series_filter({conditions, params}, value) when value in [nil, ""],
    do: {conditions, params}

  defp add_series_filter({conditions, params}, value) do
    exact = normalize_text(value)
    like = "%#{like_escape(exact)}%"
    exact_index = length(params) + 1
    like_index = length(params) + 2

    condition =
      """
      exists (
        select 1
        from series_memberships sm
        join series s on s.id = sm.series_id
        where sm.work_id = w.id
          and (
            lower(coalesce(s.slug, '')) = $#{exact_index}
            or lower(coalesce(s.title, '')) like $#{like_index} escape '!'
          )
      )
      """

    {[condition | conditions], params ++ [exact, like]}
  end

  defp add_language_filter({conditions, params}, value) when value in [nil, ""],
    do: {conditions, params}

  defp add_language_filter({conditions, params}, value) do
    index = length(params) + 1

    condition =
      "(lower(coalesce(e.language_code, '')) = $#{index} or lower(coalesce(w.original_language_code, '')) = $#{index})"

    {[condition | conditions], params ++ [normalize_text(value)]}
  end

  defp add_subject_filter({conditions, params}, value) when value in [nil, ""],
    do: {conditions, params}

  defp add_subject_filter({conditions, params}, value) do
    index = length(params) + 1

    {["w.subjects @> ARRAY[$#{index}]::text[]" | conditions], params ++ [to_string(value)]}
  end

  defp add_year_filter({conditions, params}, value) when value in [nil, ""],
    do: {conditions, params}

  defp add_year_filter({conditions, params}, value) do
    case Integer.parse(to_string(value)) do
      {year, ""} when year > 0 ->
        index = length(params) + 1
        {["extract(year from e.published_on)::int = $#{index}" | conditions], params ++ [year]}

      _invalid ->
        {["false" | conditions], params}
    end
  end

  defp work_page_order_sql(_sort), do: publication_date_order_sql()

  defp publication_date_order_sql, do: "newest_sort desc nulls last, title_sort, slug_sort"

  defp limit_params(:all, _offset, params), do: {"", params}

  defp limit_params(limit, offset, params) do
    limit_index = length(params) + 1
    offset_index = length(params) + 2
    {"limit $#{limit_index} offset $#{offset_index}", params ++ [limit, offset]}
  end

  defp normalize_book_filters(query) when is_map(query) do
    %{
      q: filter_value(query, :q) || filter_value(query, :query) || "",
      publisher: filter_value(query, :publisher),
      role: filter_value(query, :role),
      contributor: filter_value(query, :contributor),
      format: filter_value(query, :format),
      language: filter_value(query, :language),
      subject: filter_value(query, :subject),
      series: filter_value(query, :series),
      year: filter_value(query, :year),
      sort: normalize_sort(filter_value(query, :sort))
    }
  end

  defp normalize_book_filters(query) do
    normalize_book_filters(%{q: query})
  end

  defp filter_value(filters, key) do
    value = Map.get(filters, key) || Map.get(filters, to_string(key))

    cond do
      is_nil(value) -> nil
      is_binary(value) -> String.trim(value)
      is_atom(value) -> value |> Atom.to_string() |> String.trim()
      is_integer(value) -> Integer.to_string(value)
      true -> value |> to_string() |> String.trim()
    end
  end

  defp normalize_sort(sort) when sort in ~w(newest title author recently_added), do: sort
  defp normalize_sort(_sort), do: "newest"

  defp default_title_page_filters?(%{sort: "newest"} = filters) do
    Enum.all?(
      ~w(q publisher role contributor format language subject series year)a,
      fn key -> blank_filter_value?(Map.get(filters, key)) end
    )
  end

  defp default_title_page_filters?(_filters), do: false

  defp blank_filter_value?(value), do: value in [nil, ""]

  def editions do
    edition_rows("", [])
    |> Enum.map(&edition_projection_from_row/1)
    |> Enum.sort_by(&publication_date_sort_key/1)
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
    cached({:publishers}, fn ->
      publisher_summary_rows()
      |> Enum.map(&publisher_summary_from_row/1)
      |> Enum.sort_by(&String.downcase(&1.name))
    end)
  end

  def publisher(slug) do
    cached({:publisher, slug}, fn ->
      case publisher_summary_by_slug(slug) do
        nil ->
          nil

        publisher ->
          books = books_for_publisher_id(publisher.id)

          publisher
          |> Map.put(:editions, books)
          |> Map.put(:editions_count, length(books))
          |> Map.put(:groupings, publisher_groupings(books))
      end
    end)
  end

  def clear_cache do
    __MODULE__
    |> cache_registry_key()
    |> :persistent_term.get([])
    |> Enum.each(&:persistent_term.erase/1)

    :persistent_term.erase(cache_registry_key(__MODULE__))
    :ok
  end

  defp cached(key, fun) do
    if public_catalog_cache?() do
      cache_key = cache_key(key)
      now_ms = System.monotonic_time(:millisecond)

      case :persistent_term.get(cache_key, @cache_missing) do
        %{expires_at: expires_at, value: value} when expires_at == :infinity ->
          value

        %{expires_at: expires_at, value: value}
        when is_integer(expires_at) and expires_at > now_ms ->
          value

        _expired_missing_or_legacy_cache ->
          value = fun.()
          :persistent_term.put(cache_key, %{expires_at: cache_expires_at(), value: value})
          remember_cache_key(cache_key)
          value
      end
    else
      fun.()
    end
  end

  defp public_catalog_cache? do
    Application.get_env(:hiraeth, :public_catalog_cache, true)
  end

  defp cache_expires_at do
    case Application.get_env(:hiraeth, :public_catalog_cache_ttl_ms, @default_cache_ttl_ms) do
      :infinity ->
        :infinity

      ttl_ms when is_integer(ttl_ms) and ttl_ms > 0 ->
        System.monotonic_time(:millisecond) + ttl_ms

      _zero_or_invalid_ttl ->
        System.monotonic_time(:millisecond)
    end
  end

  defp cache_key(key), do: {__MODULE__, :cache, key}
  defp cache_registry_key(module), do: {module, :cache_keys}

  defp remember_cache_key(cache_key) do
    registry_key = cache_registry_key(__MODULE__)

    cache_keys =
      registry_key
      |> :persistent_term.get([])
      |> List.wrap()

    if cache_key in cache_keys do
      :ok
    else
      :persistent_term.put(registry_key, [cache_key | cache_keys])
    end
  end

  def contributors(role \\ nil) do
    role
    |> contributor_summary_rows()
    |> Enum.map(&contributor_summary_from_row/1)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  def contributor(slug) do
    case contributor_summary_by_slug(slug) do
      nil ->
        nil

      contributor ->
        books =
          slug
          |> contributor_work_ids()
          |> books_for_work_ids()

        contributor
        |> Map.put(:books, books)
        |> Map.put(:books_count, length(books))
    end
  end

  def series do
    series_summary_rows()
    |> Enum.map(&series_summary_from_row/1)
    |> Enum.sort_by(&String.downcase(&1.title))
  end

  def series_by_slug(slug) do
    case series_summary_by_slug(slug) do
      nil ->
        nil

      series ->
        books =
          series.memberships
          |> Enum.map(& &1.work_id)
          |> Enum.uniq()
          |> Enum.map(&uuid_param/1)
          |> books_for_work_ids()
          |> Enum.sort_by(&publication_date_sort_key/1)

        series
        |> Map.delete(:memberships)
        |> Map.put(:editions, books)
        |> Map.put(:editions_count, length(books))
    end
  end

  def edition(slug) do
    case work_id_for_slug(slug) do
      nil ->
        nil

      work_id ->
        work_id
        |> List.wrap()
        |> editions_for_work_ids()
        |> Enum.find(&(&1.slug == slug))
    end
  end

  defp publisher_summary_rows do
    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        with publisher_counts as (
          select p.id, p.name, p.slug, p.description, count(distinct e.work_id) as editions_count
          from publishers p
          join editions e on e.publisher_id = p.id
          where exists (
            select 1
            from source_records sr
            where sr.edition_id = e.id
          )
          group by p.id, p.name, p.slug, p.description
        )
        select
          pc.id,
          pc.name,
          pc.slug,
          pc.description,
          pc.editions_count,
          sample_cover.data
        from publisher_counts pc
        left join lateral (
          select jsonb_build_object(
            'title', e.title,
            'cover', jsonb_build_object(
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
              'thumbnail_file_path', cover.thumbnail_file_path,
              'takedown_state', cover.takedown_state
            )
          ) as data
          from editions e
          join source_records sr on sr.edition_id = e.id
          join cover_assignments ca on ca.edition_id = e.id
          join cover_assets cover on cover.id = ca.cover_asset_id
          where e.publisher_id = pc.id
            and ca."visible?" = true
            and cover.takedown_state = 'visible'
            and cover.cache_policy = 'cache_allowed'
            and cover.rights_basis = 'local_cache_permitted'
          order by e.published_on desc nulls last, e.slug, ca.position nulls last
          limit 1
        ) sample_cover on true
        """,
        []
      )

    rows
  end

  defp publisher_summary_by_slug(slug) do
    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select
          p.id,
          p.name,
          p.slug,
          p.description,
          count(distinct e.work_id) filter (
            where exists (
              select 1
              from source_records sr
              where sr.edition_id = e.id
            )
          ) as editions_count,
          count(distinct e.work_id) as total_editions_count
        from publishers p
        left join editions e on e.publisher_id = p.id
        where p.slug = $1
        group by p.id, p.name, p.slug, p.description
        limit 1
        """,
        [slug]
      )

    case List.first(rows) do
      nil ->
        nil

      [_id, _name, _slug, _description, 0, total_editions_count]
      when total_editions_count > 0 ->
        nil

      [id, name, slug, description, editions_count, _total_editions_count] ->
        publisher_summary_from_row([id, name, slug, description, editions_count, nil])
    end
  end

  defp publisher_summary_from_row([id, name, slug, description, editions_count]) do
    publisher_summary_from_row([id, name, slug, description, editions_count, nil])
  end

  defp publisher_summary_from_row([id, name, slug, description, editions_count, cover_sample]) do
    %{
      id: uuid_text(id),
      name: name,
      slug: slug,
      description: description,
      editions: [],
      editions_count: editions_count,
      cover_sample: publisher_cover_sample_from_data(cover_sample),
      groupings: empty_publisher_groupings()
    }
  end

  defp publisher_cover_sample_from_data(%{"title" => title, "cover" => cover}) do
    case cover_projection_from_data(cover) do
      nil -> nil
      cover -> %{title: title, cover: cover}
    end
  end

  defp publisher_cover_sample_from_data(_cover_sample), do: nil

  defp empty_publisher_groupings do
    %{
      formats: [],
      languages: [],
      original_languages: [],
      series: [],
      translations: [],
      contributor_roles: []
    }
  end

  defp publisher_groupings(books) do
    %{
      formats: publisher_format_groupings(books),
      languages: publisher_language_groupings(books),
      original_languages: edition_count_group(books, & &1.original_language_code),
      series: publisher_series_groupings(books),
      translations: publisher_translation_groupings(books),
      contributor_roles: publisher_contributor_role_groupings(books)
    }
  end

  defp publisher_format_groupings(books) do
    books
    |> Enum.flat_map(&Map.get(&1, :formats, []))
    |> Enum.map(&format_label(&1.format))
    |> Enum.reject(&blank?/1)
    |> bounded_count_group()
  end

  defp publisher_language_groupings(books) do
    books
    |> Enum.flat_map(&Map.get(&1, :formats, []))
    |> Enum.map(& &1.language_code)
    |> Enum.reject(&blank?/1)
    |> bounded_count_group()
  end

  defp edition_count_group(editions, value_fun) do
    editions
    |> Enum.map(value_fun)
    |> Enum.reject(&blank?/1)
    |> bounded_count_group()
  end

  defp publisher_series_groupings(editions) do
    editions
    |> Enum.flat_map(fn edition ->
      edition.series_titles
      |> Enum.with_index()
      |> Enum.map(fn {title, index} ->
        slug = if index == 0, do: edition.series_slug
        {title, slug, edition.work_id}
      end)
    end)
    |> Enum.reject(fn {title, _slug, _work_id} -> blank?(title) end)
    |> Enum.group_by(fn {title, slug, _work_id} -> {title, slug} end, fn {_title, _slug, work_id} ->
      work_id
    end)
    |> Enum.map(fn {{title, slug}, work_ids} ->
      %{label: title, slug: slug, count: work_ids |> Enum.uniq() |> length()}
    end)
    |> sort_and_bound_groups()
  end

  defp publisher_translation_groupings(editions) do
    editions
    |> Enum.filter(&translated_edition?/1)
    |> Enum.map(fn edition ->
      language_codes = edition_language_codes(edition)

      cond do
        present?(edition.original_language_code) and language_codes != [] ->
          edition_language = List.first(language_codes)
          "#{edition.original_language_code} → #{edition_language}"

        present?(edition.original_language_code) ->
          "from #{edition.original_language_code}"

        language_codes != [] ->
          "translated into #{List.first(language_codes)}"

        true ->
          "translated works"
      end
    end)
    |> bounded_count_group()
  end

  defp translated_edition?(edition) do
    language_codes = edition_language_codes(edition)

    (map_size(edition.contributors_by_role || %{}) > 0 and
       Map.has_key?(edition.contributors_by_role || %{}, "translator")) or
      (present?(edition.original_language_code) and
         Enum.any?(language_codes, &(&1 != edition.original_language_code)))
  end

  defp edition_language_codes(edition) do
    edition
    |> Map.get(:formats, [])
    |> Enum.map(& &1.language_code)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp publisher_contributor_role_groupings(editions) do
    editions
    |> Enum.flat_map(fn edition ->
      edition.contributors_by_role
      |> Enum.flat_map(fn {role, contributors} ->
        contributors
        |> Enum.map(fn contributor -> {role, contributor.slug || contributor.name} end)
      end)
    end)
    |> Enum.reject(fn {role, contributor_key} -> blank?(role) or blank?(contributor_key) end)
    |> Enum.group_by(fn {role, _contributor_key} -> role end, fn {_role, contributor_key} ->
      contributor_key
    end)
    |> Enum.map(fn {role, contributor_keys} ->
      %{label: role, count: contributor_keys |> Enum.uniq() |> length()}
    end)
    |> sort_and_bound_groups()
  end

  defp bounded_count_group(values) do
    values
    |> Enum.group_by(& &1)
    |> Enum.map(fn {value, entries} -> %{label: value, count: length(entries)} end)
    |> sort_and_bound_groups()
  end

  defp sort_and_bound_groups(groups) do
    groups
    |> Enum.sort_by(&{-&1.count, String.downcase(to_string(&1.label))})
    |> Enum.take(@publisher_group_limit)
  end

  defp contributor_summary_rows(role) do
    {where, params} = contributor_role_where(role)

    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select
          ct.id,
          ct.display_name,
          ct.slug,
          coalesce(jsonb_agg(distinct c.role) filter (where c.role is not null), '[]'::jsonb),
          count(distinct e.work_id) as books_count
        from contributors ct
        join contributions c on c.contributor_id = ct.id
        join editions e on e.work_id = c.work_id or e.id = c.edition_id
        join source_records sr on sr.edition_id = e.id
        #{where}
        group by ct.id, ct.display_name, ct.slug
        """,
        params
      )

    rows
  end

  defp contributor_summary_by_slug(slug) do
    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select
          ct.id,
          ct.display_name,
          ct.slug,
          coalesce(jsonb_agg(distinct c.role) filter (where c.role is not null), '[]'::jsonb),
          count(distinct e.work_id) as books_count
        from contributors ct
        join contributions c on c.contributor_id = ct.id
        join editions e on e.work_id = c.work_id or e.id = c.edition_id
        join source_records sr on sr.edition_id = e.id
        where ct.slug = $1
        group by ct.id, ct.display_name, ct.slug
        limit 1
        """,
        [slug]
      )

    rows |> List.first() |> then(&(&1 && contributor_summary_from_row(&1)))
  end

  defp contributor_work_ids(slug) do
    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select e.work_id
        from contributors ct
        join contributions c on c.contributor_id = ct.id
        join editions e on e.work_id = c.work_id or e.id = c.edition_id
        join source_records sr on sr.edition_id = e.id
        where ct.slug = $1
        group by e.work_id
        order by max(e.published_on) desc nulls last, min(lower(e.title)), min(e.slug)
        """,
        [slug]
      )

    Enum.map(rows, fn [work_id] -> work_id end)
  end

  defp contributor_role_where(role) do
    case normalize_contributor_role(role) do
      nil -> {"", []}
      role -> {"where c.role = $1", [role]}
    end
  end

  defp normalize_contributor_role(role) when role in [nil, ""], do: nil

  defp normalize_contributor_role(role) do
    case normalize_text(role) do
      role when role in ["author", "translator"] -> role
      _other -> "__none__"
    end
  end

  defp contributor_summary_from_row([id, display_name, slug, roles, books_count]) do
    %{
      id: uuid_text(id),
      name: display_name,
      display_name: display_name,
      slug: slug,
      roles: Enum.sort(roles || []),
      books: [],
      books_count: books_count
    }
  end

  defp series_summary_rows do
    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select
          s.id,
          s.title,
          s.slug,
          p.name,
          p.slug,
          count(distinct e.work_id) as editions_count,
          coalesce(bool_or(sm.position is null) filter (where sm.id is not null), false) as unknown_order
        from series s
        left join publishers p on p.id = s.publisher_id
        join series_memberships sm on sm.series_id = s.id
        join editions e on e.work_id = sm.work_id
        where exists (
          select 1
          from source_records sr
          where sr.edition_id = e.id
        )
        group by s.id, s.title, s.slug, p.name, p.slug
        """,
        []
      )

    rows
  end

  defp series_summary_by_slug(slug) do
    {:ok, %{rows: rows}} =
      Hiraeth.Repo.query(
        """
        select
          s.id,
          s.title,
          s.slug,
          p.name,
          p.slug,
          count(distinct e.work_id) as editions_count,
          coalesce(bool_or(sm.position is null) filter (where sm.id is not null), false) as unknown_order,
          coalesce(
            jsonb_agg(
              jsonb_build_object('work_id', sm.work_id, 'position', sm.position)
              order by coalesce(sm.position, 0), sm.id
            ) filter (where sm.id is not null),
            '[]'::jsonb
          ) as memberships
        from series s
        left join publishers p on p.id = s.publisher_id
        join series_memberships sm on sm.series_id = s.id
        join editions e on e.work_id = sm.work_id
        where s.slug = $1
          and exists (
            select 1
            from source_records sr
            where sr.edition_id = e.id
          )
        group by s.id, s.title, s.slug, p.name, p.slug
        limit 1
        """,
        [slug]
      )

    rows |> List.first() |> then(&(&1 && series_summary_from_row(&1)))
  end

  defp series_summary_from_row([
         id,
         title,
         slug,
         publisher,
         publisher_slug,
         editions_count,
         unknown_order?
       ]) do
    %{
      id: uuid_text(id),
      title: title,
      name: title,
      slug: slug,
      publisher: publisher,
      publisher_slug: publisher_slug,
      editions: [],
      editions_count: editions_count,
      unknown_order?: unknown_order?
    }
  end

  defp series_summary_from_row(row) do
    memberships = List.last(row)

    row
    |> Enum.take(7)
    |> series_summary_from_row()
    |> Map.put(:memberships, Enum.map(memberships || [], &membership_from_data/1))
  end

  defp membership_from_data(%{"work_id" => work_id, "position" => position}) do
    %{work_id: uuid_text(work_id), position: position}
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
          w.original_title,
          w.original_language_code,
          w.subjects,
          e.language_code,
          e.page_count,
          e.height_mm,
          e.width_mm,
          e.depth_mm,
          coalesce(identifiers.data, '[]'::jsonb),
          coalesce(contributors.data, '[]'::jsonb),
          coalesce(series.data, '[]'::jsonb),
          coalesce(covers.data, '[]'::jsonb),
          source.data
        from editions e
        join works w on w.id = e.work_id
        join publishers p on p.id = e.publisher_id
        join lateral (
          select jsonb_agg(i.value order by i.value) as data
          from identifiers i
          where i.edition_id = e.id and i.identifier_type = 'isbn_13'
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
            'imported_at', sr.imported_at,
            'field_sources', sr.raw_payload->'field_sources',
            'provider_permissions', sr.raw_payload->'provider_permissions',
            'source_identity', coalesce(sr.source_identity, sr.raw_payload->>'source_identity'),
            'review_links', sr.raw_payload->'review_links',
            'missing_fields', sr.raw_payload->'missing_fields'
          ) as data
          from source_records sr
          where sr.edition_id = e.id
          order by sr.imported_at desc nulls last, sr.id
          limit 1
        ) source on true
        left join lateral (
          select jsonb_agg(
            jsonb_build_object(
              'id', ct.id,
              'contribution_id', c.id,
              'position', c.position,
              'role', c.role,
              'name', ct.display_name,
              'slug', ct.slug
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
              'thumbnail_file_path', cover.thumbnail_file_path,
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
         original_title,
         original_language_code,
         subjects,
         language_code,
         page_count,
         height_mm,
         width_mm,
         depth_mm,
         identifiers,
         contributors,
         series,
         covers,
         source
       ]) do
    identifiers = Enum.sort(identifiers || [])
    contributors = contributors || []
    contributors_by_role = contributors_by_role_from_data(contributors)
    series = series || []
    cover = covers |> public_cover_data() |> cover_projection_from_data()

    %{
      id: uuid_text(id),
      work_id: uuid_text(work_id),
      title: title,
      subtitle: subtitle,
      slug: slug,
      format: format,
      published_on: published_on,
      year: published_on && published_on.year,
      publisher: publisher,
      publisher_slug: publisher_slug,
      author: contributor_text_from_data(contributors),
      authors: Map.get(contributors_by_role, "author", []),
      translators: Map.get(contributors_by_role, "translator", []),
      contributors_by_role: contributors_by_role,
      contributor_names: contributor_names_from_data(contributors),
      identifiers: identifiers,
      isbn: List.first(identifiers),
      series_titles: series_titles_from_data(series),
      series_slug: first_series_slug_from_data(series),
      cover: cover,
      description: description,
      editorial_praise: editorial_praise || [],
      storefront_url: storefront_url,
      original_title: original_title,
      original_language_code: original_language_code,
      subjects: subjects || [],
      language_code: language_code,
      page_count: page_count,
      height_mm: height_mm,
      width_mm: width_mm,
      depth_mm: depth_mm,
      dimensions: dimensions_projection(height_mm, width_mm, depth_mm),
      source: atomize_source(source),
      source_uri: source && source["source_uri"],
      review_links: source_review_links(source),
      missing_fields: source_missing_fields(source)
    }
  end

  defp book_projection(editions) do
    editions = Enum.sort_by(editions, &format_sort_key/1)
    primary = List.first(editions)
    latest_published_on = latest_published_on(editions)

    %{}
    |> Map.merge(
      Map.take(primary, [
        :work_id,
        :title,
        :subtitle,
        :publisher,
        :publisher_slug,
        :author,
        :authors,
        :translators,
        :contributors_by_role,
        :contributor_names,
        :series_titles,
        :series_slug,
        :cover,
        :source,
        :original_title,
        :original_language_code,
        :subjects
      ])
    )
    |> Map.put(:id, primary.work_id)
    |> Map.put(:slug, work_slug(primary))
    |> Map.put(:description, first_present(editions, :description))
    |> Map.put(:editorial_praise, first_present(editions, :editorial_praise) || [])
    |> Map.put(:praise, first_present(editions, :editorial_praise) || [])
    |> Map.put(:storefront_url, first_present(editions, :storefront_url))
    |> Map.put(:review_links, first_present(editions, :review_links) || [])
    |> Map.put(:missing_fields, merge_missing_fields(editions))
    |> Map.put(:formats, Enum.map(editions, &format_projection/1))
    |> Map.put(
      :identifiers,
      editions |> Enum.flat_map(& &1.identifiers) |> Enum.uniq() |> Enum.sort()
    )
    |> Map.put(:isbn, editions |> Enum.flat_map(& &1.identifiers) |> Enum.uniq() |> List.first())
    |> Map.put(:sources, editions |> Enum.map(& &1.source) |> Enum.reject(&is_nil/1))
    |> Map.put(:published_on, latest_published_on)
    |> Map.put(:year, latest_published_on && latest_published_on.year)
  end

  defp latest_published_on(editions) do
    editions
    |> Enum.map(& &1.published_on)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(Date, fn -> nil end)
  end

  defp format_projection(edition) do
    %{
      edition_slug: edition.slug,
      format: edition.format,
      format_label: format_label(edition.format),
      identifiers: edition.identifiers,
      source_identity:
        if(edition.identifiers == [],
          do: get_in(edition, [:source, :source_identity]) || edition.slug,
          else: nil
        ),
      published_on: edition.published_on,
      language_code: edition.language_code,
      page_count: edition.page_count,
      height_mm: edition.height_mm,
      width_mm: edition.width_mm,
      depth_mm: edition.depth_mm,
      dimensions: edition.dimensions
    }
  end

  defp dimensions_projection(nil, nil, nil), do: nil

  defp dimensions_projection(height_mm, width_mm, depth_mm) do
    %{
      height_mm: height_mm,
      width_mm: width_mm,
      depth_mm: depth_mm
    }
  end

  defp source_review_links(source) when is_map(source), do: source["review_links"] || []
  defp source_review_links(_source), do: []

  defp source_missing_fields(source) when is_map(source), do: source["missing_fields"] || %{}
  defp source_missing_fields(_source), do: %{}

  defp merge_missing_fields(editions) do
    editions
    |> Enum.map(&Map.get(&1, :missing_fields, %{}))
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
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
      takedown_state: asset["takedown_state"],
      cached_file_path: asset["cached_file_path"],
      thumbnail_file_path: asset["thumbnail_file_path"],
      thumbnail_url: thumbnail_url_from_data(asset["thumbnail_file_path"])
    }
  end

  defp cover_public_url_from_data(%{
         "cache_policy" => "cache_allowed",
         "cached_file_path" => path
       })
       when is_binary(path) do
    static_cover_path(path)
  end

  defp cover_public_url_from_data(_asset), do: nil

  defp thumbnail_url_from_data(path) do
    if safe_cached_file_path?(path), do: static_cover_path(path)
  end

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

  defp contributors_by_role_from_data(contributors) do
    contributors
    |> Enum.sort_by(&{&1["position"] || 0, &1["role"], &1["id"]})
    |> Enum.reduce(%{}, fn contributor, grouped ->
      role = contributor["role"] || "contributor"

      entry = %{
        id: uuid_text(contributor["id"]),
        name: contributor["name"],
        slug: contributor["slug"],
        role: role,
        position: contributor["position"]
      }

      Map.update(grouped, role, [entry], &(&1 ++ [entry]))
    end)
    |> Map.new(fn {role, entries} ->
      {role, Enum.uniq_by(entries, &{&1.name, &1.slug, &1.role})}
    end)
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

  defp publication_date_sort_key(edition) do
    published_rank =
      case edition.published_on do
        %Date{} = date -> -Date.to_gregorian_days(date)
        _missing -> -@undated_sort_value
      end

    {published_rank, String.downcase(edition.title || ""), edition.slug}
  end

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
      id: uuid_text(source["id"]),
      source_record_id: uuid_text(source["source_record_id"]),
      provider: source["provider"],
      source_type: source["source_type"],
      source_uri: source["source_uri"],
      source_identity: source["source_identity"],
      license_note: source["license_note"],
      import_run_id: source["import_run_id"],
      imported_at: parse_imported_at(source["imported_at"]),
      field_sources: source["field_sources"] || %{},
      provider_permissions: source["provider_permissions"] || %{}
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

    with true <- String.starts_with?(path, cache_root <> "/"),
         true <- cache_root_directory?(cache_root),
         true <- no_symlink_components?(path, cache_root),
         true <- File.regular?(path) do
      true
    else
      _ -> false
    end
  end

  defp safe_cached_file_path?(_path), do: false

  defp cache_root_directory?(cache_root) do
    case File.lstat(cache_root) do
      {:ok, %{type: :directory}} -> true
      _ -> false
    end
  end

  defp no_symlink_components?(path, cache_root) do
    path
    |> Path.relative_to(cache_root)
    |> Path.split()
    |> Enum.reduce_while(cache_root, fn component, parent ->
      current = Path.join(parent, component)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> {:halt, false}
        {:ok, _stat} -> {:cont, current}
        {:error, _reason} -> {:halt, false}
      end
    end)
    |> is_binary()
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp parse_uri(value) when is_binary(value), do: URI.parse(value)
  defp parse_uri(_value), do: %URI{}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp uuid_text(value) when is_binary(value) and byte_size(value) == 16 do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp uuid_text(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp uuid_text(value), do: value

  defp uuid_param(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp uuid_param(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, raw_uuid} -> raw_uuid
      :error -> value
    end
  end

  defp uuid_param(value), do: value

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
