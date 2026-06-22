defmodule Hiraeth.RealCatalog.Importer do
  @moduledoc """
  Idempotently imports the tracked real-publisher catalog dataset into Ash resources.
  """

  alias Hiraeth.Catalog.{
    Contribution,
    Contributor,
    Edition,
    Identifier,
    Imprint,
    Publisher,
    Series,
    SeriesMembership,
    Work
  }

  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.RealCatalog.{Dataset, ISBN, Slug, Validator}
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  require Ash.Query

  @import_cache_key {__MODULE__, :import_cache}
  @contributions_by_edition_cache_key {__MODULE__, :contributions_by_edition_cache}
  @contribution_key_cache_key {__MODULE__, :contribution_key_cache}
  @previous_source_work_cache_key {__MODULE__, :previous_source_work_cache}

  def seed!(dir \\ Dataset.default_dir()) do
    Process.put(@import_cache_key, %{})

    try do
      with {:ok, datasets} <- Dataset.load_dir(dir),
           {:ok, _summary} <- Validator.validate_datasets(datasets) do
        prune_stale? = Path.expand(dir) == Path.expand(Dataset.default_dir())

        Enum.each(datasets, &import_dataset!(&1, prune_stale?))
        {:ok, summary()}
      end
    after
      Process.delete(@import_cache_key)
      Process.delete(@contributions_by_edition_cache_key)
      Process.delete(@contribution_key_cache_key)
      Process.delete(@previous_source_work_cache_key)
    end
  end

  def seed_provider!(dataset, import_run) do
    Process.put(@import_cache_key, %{})

    try do
      Hiraeth.Repo.transaction(fn ->
        Enum.each(dataset.records, &import_record!(dataset, &1, import_run))
        prune_stale_source_records!(dataset.provider, dataset.file_checksum)
        summary()
      end)
      |> case do
        {:ok, summary} -> {:ok, summary}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        {:error, e}
    after
      Process.delete(@import_cache_key)
      Process.delete(@contributions_by_edition_cache_key)
      Process.delete(@contribution_key_cache_key)
      Process.delete(@previous_source_work_cache_key)
    end
  end

  defp import_dataset!(dataset, prune_stale?) do
    import_run = ensure_import_run!(dataset)

    Enum.each(dataset.records, &import_record!(dataset, &1, import_run))

    if prune_stale? do
      prune_stale_source_records!(dataset.provider, dataset.file_checksum)
    end
  end

  defp import_record!(dataset, record, import_run) do
    publisher_slug = Slug.slugify(record.publisher)

    publisher =
      find_or_create!(
        Publisher,
        :slug,
        publisher_slug,
        %{name: record.publisher, slug: publisher_slug},
        trusted_write_opts()
      )

    imprint =
      if present?(record.imprint) do
        imprint_slug = Slug.slugify(record.imprint)

        find_or_create_by!(
          Imprint,
          &(&1.publisher_id == publisher.id and &1.slug == imprint_slug),
          %{name: record.imprint, slug: imprint_slug, publisher_id: publisher.id},
          trusted_write_opts()
        )
      end

    work_slug = work_slug(record, publisher_slug)

    work =
      find_or_create!(
        Work,
        :slug,
        work_slug,
        work_attrs(record, work_slug),
        trusted_write_opts()
      )
      |> sync_work_metadata!(record, dataset.file_checksum, trusted_write_opts())

    edition =
      record
      |> find_or_create_edition!(publisher, imprint, work)
      |> sync_edition_metadata!(record, work, publisher, imprint, trusted_write_opts())

    ensure_identifier!(edition, dataset, record, trusted_write_opts())
    ensure_contributions!(record, work, edition, trusted_write_opts())
    ensure_series_memberships!(record, publisher, work, trusted_write_opts())
    ensure_cover!(record, edition, trusted_write_opts())
    ensure_source_record!(dataset, record, edition, import_run, trusted_write_opts())
  end

  defp work_attrs(record, work_slug) do
    %{
      title: display_title(record, :work),
      subtitle: record.work.subtitle,
      slug: work_slug,
      publication_state: record.work.publication_state || "published"
    }
    |> Map.merge(work_metadata_attrs(record))
  end

  defp sync_work_metadata!(work, record, current_file_checksum, write_opts) do
    updates =
      record
      |> work_metadata_attrs()
      |> Enum.reject(fn {key, value} ->
        blank_metadata?(value) or Map.get(work, key) == value or
          not source_safe_work_update?(work, key, current_file_checksum)
      end)
      |> Map.new()

    if updates == %{} do
      work
    else
      work
      |> Ash.Changeset.for_update(:update, updates)
      |> Ash.update!(write_opts)
      |> replace_cached_record(Work)
    end
  end

  defp source_safe_work_update?(_work, key, _current_file_checksum)
       when key in [
              :title,
              :subtitle,
              :publication_state,
              :original_title,
              :original_language_code,
              :subjects
            ],
       do: true

  defp source_safe_work_update?(work, key, current_file_checksum)
       when key in [:description, :storefront_url, :editorial_praise] do
    current_value = Map.get(work, key)

    blank_metadata?(current_value) or
      current_value == previous_source_work_value(work, key, current_file_checksum)
  end

  defp source_safe_work_update?(_work, _key, _current_file_checksum), do: false

  defp previous_source_work_value(work, key, current_file_checksum) do
    current_file_checksum
    |> previous_source_work_values()
    |> Map.get({work.id, key})
  end

  defp previous_source_work_values(current_file_checksum) do
    cache = Process.get(@previous_source_work_cache_key, %{})

    case Map.fetch(cache, current_file_checksum) do
      {:ok, values} ->
        values

      :error ->
        edition_work_ids =
          Edition
          |> cached_read()
          |> Map.new(&{&1.id, &1.work_id})

        values =
          SourceRecord
          |> cached_read()
          |> Enum.reject(&(&1.file_checksum == current_file_checksum))
          |> Enum.filter(&Map.has_key?(edition_work_ids, &1.edition_id))
          |> Enum.sort_by(&(&1.imported_at || ~U[0001-01-01 00:00:00Z]), {:desc, DateTime})
          |> Enum.reduce(%{}, fn source_record, acc ->
            work_id = Map.fetch!(edition_work_ids, source_record.edition_id)
            payload = source_record.raw_payload || %{}

            [:description, :storefront_url, :editorial_praise]
            |> Enum.reduce(acc, fn key, acc ->
              value = source_payload_value(payload, key)

              if blank_metadata?(value) do
                acc
              else
                Map.put_new(acc, {work_id, key}, value)
              end
            end)
          end)

        Process.put(
          @previous_source_work_cache_key,
          Map.put(cache, current_file_checksum, values)
        )

        values
    end
  end

  defp source_payload_value(payload, :description), do: map_value(payload, "description")
  defp source_payload_value(payload, :storefront_url), do: map_value(payload, "storefront_url")

  defp source_payload_value(payload, :editorial_praise),
    do: map_value(payload, "editorial_praise")

  defp source_payload_value(_payload, _key), do: nil

  defp work_metadata_attrs(record) do
    %{}
    |> maybe_put_metadata(:title, display_title(record, :work))
    |> maybe_put_metadata(:subtitle, get_in(record, [:work, :subtitle]))
    |> maybe_put_metadata(:publication_state, get_in(record, [:work, :publication_state]))
    |> maybe_put_metadata(:original_title, get_in(record, [:work, :original_title]))
    |> maybe_put_metadata(
      :original_language_code,
      get_in(record, [:work, :original_language_code])
    )
    |> maybe_put_metadata(:subjects, get_in(record, [:work, :subjects]))
    |> maybe_put_metadata(:description, prose_description(record))
    |> maybe_put_metadata(:storefront_url, Map.get(record, :storefront_url))
    |> maybe_put_metadata(:editorial_praise, editorial_praise(record))
  end

  defp prose_description(record),
    do:
      Map.get(record, :description) || Map.get(record, :synopsis) ||
        get_in(record, [:work, :description]) || get_in(record, [:work, :synopsis])

  defp editorial_praise(record) do
    record
    |> Map.get(:editorial_praise, [])
    |> List.wrap()
    |> Enum.map(fn praise ->
      %{}
      |> maybe_put_metadata("quote", map_value(praise, :quote))
      |> maybe_put_metadata("source", map_value(praise, :source))
      |> maybe_put_metadata("source_uri", map_value(praise, :source_uri))
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp display_title(record, scope) do
    raw_title = get_in(record, [scope, :title]) || ""

    record
    |> contributor_names()
    |> Enum.reduce(String.trim(raw_title), &strip_contributor_from_title/2)
    |> then(fn title -> if title == "", do: raw_title, else: title end)
  end

  defp contributor_names(record) do
    record
    |> Map.get(:contributors, [])
    |> List.wrap()
    |> Enum.filter(&(map_value(&1, :role) == "author"))
    |> Enum.map(&map_value(&1, :name))
    |> Enum.reject(&(blank_metadata?(&1) or String.starts_with?(String.downcase(&1), "unknown")))
    |> Enum.sort_by(&String.length/1, :desc)
  end

  defp strip_contributor_from_title(author_name, title) do
    author_name
    |> title_author_prefixes()
    |> Enum.reduce(title, fn prefix, current ->
      current
      |> then(&Regex.replace(~r/^\s*#{Regex.escape(prefix)}\s*:\s*/iu, &1, ""))
      |> then(&Regex.replace(~r/\s+by\s+#{Regex.escape(prefix)}\s*$/iu, &1, ""))
      |> String.trim()
    end)
  end

  defp title_author_prefixes(author_name) do
    reversed =
      case String.split(author_name, ~r/\s+/, trim: true) do
        [] -> nil
        [_single] -> nil
        parts -> "#{List.last(parts)}, #{parts |> Enum.drop(-1) |> Enum.join(" ")}"
      end

    [author_name, reversed]
    |> Enum.reject(&blank_metadata?/1)
  end

  defp maybe_put_metadata(map, _key, value) when value in [nil, "", []], do: map

  defp maybe_put_metadata(map, key, value) when is_binary(value),
    do: Map.put(map, key, String.trim(value))

  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp blank_metadata?(value), do: value in [nil, "", []]

  defp find_or_create_edition!(record, publisher, imprint, work) do
    slug = edition_slug(record)

    existing =
      case normalized_isbn(record) do
        nil ->
          nil

        isbn ->
          Identifier
          |> cached_read()
          |> Enum.find(&(&1.identifier_type == "isbn_13" and &1.value == isbn))
      end

    cond do
      existing ->
        Edition
        |> cached_read()
        |> Enum.find(&(&1.id == existing.edition_id))

      edition = existing_edition_by_slug(slug) ->
        edition

      true ->
        attrs = %{
          title: display_title(record, :edition),
          subtitle: record.edition.subtitle,
          slug: slug,
          format: record.edition.format,
          language_code: Map.get(record.edition, :language_code),
          page_count: Map.get(record.edition, :page_count),
          height_mm: dimension_value(record, :height_mm),
          width_mm: dimension_value(record, :width_mm),
          depth_mm: dimension_value(record, :depth_mm),
          published_on: parse_date(Map.get(record.edition, :published_on)),
          work_id: work.id,
          publisher_id: publisher.id,
          imprint_id: if(imprint, do: imprint.id, else: nil)
        }

        Edition
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create!(trusted_write_opts())
        |> cache_record(Edition)
    end
  end

  defp existing_edition_by_slug(slug) do
    Edition
    |> cached_read()
    |> Enum.find(&(&1.slug == slug))
  end

  defp sync_edition_metadata!(edition, record, work, publisher, imprint, write_opts) do
    updates =
      record
      |> edition_metadata_attrs(work, publisher, imprint)
      |> Enum.reject(fn {key, value} ->
        blank_metadata?(value) or Map.get(edition, key) == value
      end)
      |> Map.new()

    if updates == %{} do
      edition
    else
      edition
      |> Ash.Changeset.for_update(:update, updates)
      |> Ash.update!(write_opts)
    end
  end

  defp edition_metadata_attrs(record, work, publisher, imprint) do
    %{}
    |> maybe_put_metadata(:title, display_title(record, :edition))
    |> maybe_put_metadata(:subtitle, Map.get(record.edition, :subtitle))
    |> maybe_put_metadata(:format, Map.get(record.edition, :format))
    |> maybe_put_metadata(:published_on, parse_date(Map.get(record.edition, :published_on)))
    |> maybe_put_metadata(:language_code, Map.get(record.edition, :language_code))
    |> maybe_put_metadata(:page_count, Map.get(record.edition, :page_count))
    |> maybe_put_metadata(:height_mm, dimension_value(record, :height_mm))
    |> maybe_put_metadata(:width_mm, dimension_value(record, :width_mm))
    |> maybe_put_metadata(:depth_mm, dimension_value(record, :depth_mm))
    |> maybe_put_metadata(:work_id, work.id)
    |> maybe_put_metadata(:publisher_id, publisher.id)
    |> maybe_put_metadata(:imprint_id, if(imprint, do: imprint.id, else: nil))
  end

  defp dimension_value(record, key) do
    dimensions = Map.get(record.edition, :dimensions) || %{}
    map_value(dimensions, key)
  end

  defp ensure_identifier!(edition, dataset, record, write_opts) do
    case normalized_isbn(record) do
      nil ->
        find_or_create_by!(
          Identifier,
          &(&1.identifier_type == "source_record" and &1.value == source_identity(dataset, record)),
          %{
            identifier_type: "source_record",
            value: source_identity(dataset, record),
            edition_id: edition.id
          },
          write_opts
        )

      isbn ->
        find_or_create_by!(
          Identifier,
          &(&1.identifier_type == "isbn_13" and &1.value == isbn),
          %{identifier_type: "isbn_13", value: isbn, edition_id: edition.id},
          write_opts
        )
    end
  end

  defp ensure_contributions!(record, work, edition, write_opts) do
    desired_contributions =
      record.contributors
      |> Enum.uniq_by(fn contributor_data ->
        {Slug.slugify(contributor_data.name), contributor_data.role}
      end)
      |> Enum.with_index(1)
      |> Enum.map(fn {contributor_data, position} ->
        contributor_slug = Slug.slugify(contributor_data.name)

        contributor =
          find_or_create!(
            Contributor,
            :slug,
            contributor_slug,
            %{
              display_name: contributor_data.name,
              sort_name: contributor_data.name,
              slug: contributor_slug
            },
            write_opts
          )

        %{contributor: contributor, data: contributor_data, position: position}
      end)

    prune_stale_contributions!(desired_contributions, edition, write_opts)

    Enum.each(desired_contributions, fn %{
                                          contributor: contributor,
                                          data: contributor_data,
                                          position: position
                                        } ->
      contribution =
        find_or_create_contribution!(
          %{
            contributor_id: contributor.id,
            edition_id: edition.id,
            work_id: work.id,
            role: contributor_data.role,
            position: position
          },
          write_opts
        )

      sync_contribution_position!(contribution, position, write_opts)
    end)
  end

  defp prune_stale_contributions!(desired_contributions, edition, write_opts) do
    desired_keys =
      desired_contributions
      |> MapSet.new(fn %{contributor: contributor, data: contributor_data} ->
        {contributor.id, contributor_data.role}
      end)

    edition.id
    |> cached_contributions_for_edition()
    |> Enum.reject(&MapSet.member?(desired_keys, {&1.contributor_id, &1.role}))
    |> Enum.each(fn contribution ->
      Ash.destroy!(contribution, write_opts)
      uncache_record(contribution, Contribution)
    end)
  end

  defp find_or_create_contribution!(attrs, write_opts) do
    key = {attrs.edition_id, attrs.contributor_id, attrs.role}

    case cached_contribution_by_key(key) do
      nil ->
        contribution =
          Contribution
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create!(write_opts)
          |> cache_record(Contribution)

        remember_contribution_by_key(key, contribution)
        contribution

      contribution ->
        contribution
    end
  end

  defp cached_contribution_by_key(key) do
    contribution_by_key =
      case Process.get(@contribution_key_cache_key) do
        nil ->
          keyed =
            Contribution
            |> cached_read()
            |> Map.new(fn contribution ->
              {{contribution.edition_id, contribution.contributor_id, contribution.role},
               contribution}
            end)

          Process.put(@contribution_key_cache_key, keyed)
          keyed

        keyed ->
          keyed
      end

    Map.get(contribution_by_key, key)
  end

  defp remember_contribution_by_key(key, contribution) do
    contribution_by_key = Process.get(@contribution_key_cache_key, %{})
    Process.put(@contribution_key_cache_key, Map.put(contribution_by_key, key, contribution))
    contribution
  end

  defp cached_contributions_for_edition(edition_id) do
    contributions_by_edition =
      case Process.get(@contributions_by_edition_cache_key) do
        nil ->
          grouped =
            Contribution
            |> cached_read()
            |> Enum.group_by(& &1.edition_id)

          Process.put(@contributions_by_edition_cache_key, grouped)
          grouped

        grouped ->
          grouped
      end

    Map.get(contributions_by_edition, edition_id, [])
  end

  defp sync_contribution_position!(contribution, position, write_opts) do
    if contribution.position == position do
      contribution
    else
      contribution
      |> Ash.Changeset.for_update(:update, %{position: position})
      |> Ash.update!(write_opts)
      |> replace_cached_record(Contribution)
    end
  end

  defp ensure_series_memberships!(record, publisher, work, write_opts) do
    record
    |> Map.get(:series, [])
    |> List.wrap()
    |> Enum.filter(&(present?(map_value(&1, :title)) and present?(map_value(&1, :slug))))
    |> Enum.each(fn series_data ->
      series =
        find_or_create!(
          Series,
          :slug,
          map_value(series_data, :slug),
          %{
            title: map_value(series_data, :title),
            slug: map_value(series_data, :slug),
            publisher_id: publisher.id
          },
          write_opts
        )

      find_or_create_by!(
        SeriesMembership,
        &(&1.series_id == series.id and &1.work_id == work.id),
        %{
          series_id: series.id,
          work_id: work.id,
          position: map_value(series_data, :position),
          label: map_value(series_data, :label)
        },
        write_opts
      )
    end)
  end

  defp ensure_cover!(record, edition, write_opts) do
    if cover_source_url_present?(record) do
      cover = record.cover

      asset =
        find_or_create!(
          CoverAsset,
          :source_url,
          cover.source_url,
          cover_asset_attrs(cover),
          write_opts
        )
        |> sync_cover_asset!(cover, write_opts)

      find_or_create_by!(
        CoverAssignment,
        &(&1.edition_id == edition.id and &1.cover_asset_id == asset.id),
        %{edition_id: edition.id, cover_asset_id: asset.id, position: 1, visible?: true},
        write_opts
      )

      prune_stale_cover_assignments!(edition, asset.id, write_opts)
    else
      prune_stale_cover_assignments!(edition, nil, write_opts)
    end
  end

  defp prune_stale_cover_assignments!(edition, desired_cover_asset_id, write_opts) do
    CoverAssignment
    |> cached_read()
    |> Enum.filter(&(&1.edition_id == edition.id))
    |> Enum.reject(&(&1.cover_asset_id == desired_cover_asset_id))
    |> Enum.each(fn assignment ->
      Ash.destroy!(assignment, write_opts)
      uncache_record(assignment, CoverAssignment)
    end)
  end

  defp cover_asset_attrs(cover) do
    %{
      source_url: cover.source_url,
      provider: cover.provider,
      rights_basis: cover.rights_basis,
      attribution_text: cover.attribution_text,
      attribution_url: cover.attribution_url,
      cache_policy: cover.cache_policy,
      takedown_state: "visible"
    }
  end

  defp sync_cover_asset!(asset, cover, write_opts) do
    updates = %{
      provider: cover.provider,
      rights_basis: cover.rights_basis,
      attribution_text: cover.attribution_text,
      attribution_url: cover.attribution_url,
      cache_policy: cover.cache_policy
    }

    updates =
      if cover.cache_policy == "link_only" do
        Map.merge(updates, %{cached_file_path: nil, thumbnail_file_path: nil, cached_at: nil})
      else
        updates
      end

    updates =
      updates
      |> Enum.reject(fn {key, value} -> Map.get(asset, key) == value end)
      |> Map.new()

    if updates == %{} do
      asset
    else
      asset
      |> Ash.Changeset.for_update(:update, updates)
      |> Ash.update!(write_opts)
    end
  end

  defp ensure_source_record!(dataset, record, edition, import_run, write_opts) do
    checksum = dataset.file_checksum
    source_uri = edition_source_uri(record)

    source_record =
      find_source_record(dataset.provider, "publisher_dataset", source_uri, checksum) ||
        SourceRecord
        |> Ash.Changeset.for_create(:create, %{
          provider: dataset.provider,
          source_type: "publisher_dataset",
          source_uri: source_uri,
          file_checksum: checksum,
          license_note: dataset.license_note,
          source_identity: source_identity(dataset, record),
          raw_payload: raw_payload(dataset, record),
          imported_at: DateTime.utc_now(:second),
          import_run_id: import_run.id,
          edition_id: edition.id
        })
        |> Ash.create!(write_opts)
        |> cache_record(SourceRecord)

    ensure_source_ledger_entry!(source_record, record, write_opts)

    source_record
  end

  defp prune_stale_source_records!(provider, file_checksum) do
    Hiraeth.Repo.query!(
      """
      delete from source_ledger_entries ledger
      using source_records source
      where ledger.source_record_id = source.id
        and source.provider = $1
        and source.source_type = 'publisher_dataset'
        and coalesce(source.file_checksum, '') <> $2
      """,
      [provider, file_checksum]
    )

    Hiraeth.Repo.query!(
      """
      delete from curation_overrides override
      using source_records source
      where override.source_record_id = source.id
        and source.provider = $1
        and source.source_type = 'publisher_dataset'
        and coalesce(source.file_checksum, '') <> $2
      """,
      [provider, file_checksum]
    )

    Hiraeth.Repo.query!(
      """
      delete from source_records
      where provider = $1
        and source_type = 'publisher_dataset'
        and coalesce(file_checksum, '') <> $2
      """,
      [provider, file_checksum]
    )

    :ok
  end

  defp find_source_record(provider, source_type, source_uri, file_checksum) do
    SourceRecord
    |> cached_read()
    |> Enum.find(
      &(&1.provider == provider and &1.source_type == source_type and &1.source_uri == source_uri and
          &1.file_checksum == file_checksum)
    )
  end

  defp ensure_source_ledger_entry!(source_record, record, write_opts) do
    find_or_create_by!(
      SourceLedgerEntry,
      &(&1.source_record_id == source_record.id and &1.event_type == "real_catalog_seeded"),
      %{
        source_record_id: source_record.id,
        event_type: "real_catalog_seeded",
        message:
          "Seeded public catalog metadata for #{record.edition.title} from #{source_record.provider}; raw payload is checksum-versioned and immutable.",
        occurred_at: DateTime.utc_now(:second)
      },
      write_opts
    )
  end

  defp raw_payload(dataset, record) do
    %{
      "provenance" => dataset.provider,
      "source_product_id" => record.source_product_id,
      "source_identity" => source_identity(dataset, record),
      "source_sku" => record.source_sku,
      "displayed_fields" => record.displayed_fields,
      "publisher" => record.publisher,
      "imprint" => record.imprint,
      "provider_permissions" => Map.get(dataset, :provider_permissions),
      "field_sources" => Map.get(record, :field_sources),
      "work" =>
        Map.take(record.work, [
          :title,
          :subtitle,
          :original_title,
          :original_language_code,
          :subjects,
          :publication_state
        ]),
      "edition" => edition_payload(record),
      "contributors" => Enum.map(record.contributors, &Map.take(&1, [:name, :role])),
      "curation" => Map.take(record.curation, [:status, :notes])
    }
    |> maybe_put_payload_value("identifier", source_identifier_payload(dataset, record))
    |> maybe_put_payload_value("description", prose_description(record))
    |> maybe_put_payload_value("storefront_url", Map.get(record, :storefront_url))
    |> maybe_put_payload_value("editorial_praise", editorial_praise(record))
    |> maybe_put_payload_value("review_links", Map.get(record, :review_links))
    |> maybe_put_payload_value("series", series_payload(record))
    |> maybe_put_payload_value("missing_fields", Map.get(record, :missing_fields))
    |> maybe_put_cover_payload(record)
    |> maybe_put_no_cover_reason(record)
  end

  defp series_payload(record) do
    record
    |> Map.get(:series, [])
    |> List.wrap()
    |> Enum.map(&Map.take(&1, [:title, :slug, :position, :label, :source_uri]))
    |> Enum.reject(&(&1 == %{}))
  end

  defp edition_payload(record) do
    record.edition
    |> Map.take([
      :title,
      :subtitle,
      :format,
      :language_code,
      :page_count,
      :dimensions,
      :published_on
    ])
    |> maybe_put_payload_value(:isbn_13, normalized_isbn(record))
  end

  defp source_identifier_payload(dataset, record) do
    if normalized_isbn(record),
      do: nil,
      else: %{"source_identity" => source_identity(dataset, record)}
  end

  defp maybe_put_cover_payload(payload, record) do
    if cover_source_url_present?(record),
      do: put_cover_payload(payload, record.cover),
      else: payload
  end

  defp put_cover_payload(payload, cover) do
    Map.put(
      payload,
      "cover",
      Map.take(cover, [
        :source_url,
        :provider,
        :rights_basis,
        :attribution_text,
        :attribution_url,
        :cache_policy
      ])
    )
  end

  defp maybe_put_no_cover_reason(payload, record) do
    no_cover_reason = Map.get(record, :no_cover_reason) || Map.get(record, :cover_fallback_reason)

    if present?(no_cover_reason),
      do: Map.put(payload, "no_cover_reason", no_cover_reason),
      else: payload
  end

  defp maybe_put_payload_value(payload, _key, value) when value in [nil, "", []], do: payload
  defp maybe_put_payload_value(payload, key, value), do: Map.put(payload, key, value)

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_value(_value, _key), do: nil

  defp find_or_create!(resource, key, value, attrs, write_opts) do
    find_or_create_by!(resource, &(Map.get(&1, key) == value), attrs, write_opts)
  end

  defp find_or_create_by!(resource, predicate, attrs, write_opts) do
    resource
    |> cached_read()
    |> Enum.find(predicate) ||
      resource
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!(write_opts)
      |> cache_record(resource)
  end

  defp cached_read(resource) do
    cache = Process.get(@import_cache_key, %{})

    case Map.fetch(cache, resource) do
      {:ok, records} ->
        records

      :error ->
        records = Ash.read!(resource, authorize?: false)
        Process.put(@import_cache_key, Map.put(cache, resource, records))
        records
    end
  end

  defp cache_record(record, resource) do
    cache = Process.get(@import_cache_key, %{})
    records = Map.get(cache, resource, [])
    Process.put(@import_cache_key, Map.put(cache, resource, [record | records]))
    record
  end

  defp replace_cached_record(record, resource) do
    cache = Process.get(@import_cache_key, %{})

    records =
      resource
      |> cached_read()
      |> Enum.map(fn cached_record ->
        if cached_record.id == record.id, do: record, else: cached_record
      end)

    Process.put(@import_cache_key, Map.put(cache, resource, records))
    record
  end

  defp uncache_record(record, resource) do
    cache = Process.get(@import_cache_key, %{})

    records =
      resource
      |> cached_read()
      |> Enum.reject(&(&1.id == record.id))

    Process.put(@import_cache_key, Map.put(cache, resource, records))
    record
  end

  defp summary do
    %{
      publishers: Publisher |> Ash.read!(authorize?: false) |> length(),
      editions: Edition |> Ash.read!(authorize?: false) |> length(),
      identifiers: Identifier |> Ash.read!(authorize?: false) |> length(),
      source_records: SourceRecord |> Ash.read!(authorize?: false) |> length(),
      cover_assignments: CoverAssignment |> Ash.read!(authorize?: false) |> length(),
      import_runs: ImportRun |> Ash.read!(authorize?: false) |> length()
    }
  end

  defp ensure_import_run!(dataset) do
    find_or_create_by!(
      ImportRun,
      &(&1.provider == dataset.provider and &1.status == "applied"),
      %{provider: dataset.provider, status: "applied", row_limit: length(dataset.records || [])},
      trusted_write_opts()
    )
  end

  defp parse_date(nil), do: nil
  defp parse_date(value), do: Date.from_iso8601!(value)

  defp work_slug(record, publisher_slug),
    do: "#{publisher_slug}-#{Slug.slugify(display_title(record, :work))}"

  defp edition_slug(record) do
    identity = normalized_isbn(record) || "source-#{Slug.slugify(record.source_product_id)}"

    title_slug = record |> display_title(:edition) |> Slug.slugify()
    "#{Slug.slugify(record.publisher)}-#{title_slug}-#{record.edition.format}-#{identity}"
  end

  defp edition_source_uri(record) do
    case normalized_isbn(record) do
      nil -> "#{record.source_uri}#source-#{record.source_product_id}"
      isbn -> "#{record.source_uri}#isbn-#{isbn}"
    end
  end

  defp source_identity(dataset, record) do
    normalized_isbn(record) || "source:#{dataset.provider}:#{record.source_product_id}"
  end

  defp normalized_isbn(record) do
    case ISBN.normalize(Map.get(record.edition, :isbn_13)) do
      {:ok, isbn} -> isbn
      {:error, _reason} -> nil
    end
  end

  defp trusted_write_opts, do: [authorize?: false]

  defp cover_source_url_present?(%{cover: cover}) when is_map(cover),
    do: present?(Map.get(cover, :source_url))

  defp cover_source_url_present?(_record), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
