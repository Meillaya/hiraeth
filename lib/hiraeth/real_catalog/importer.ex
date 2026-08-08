defmodule Hiraeth.RealCatalog.Importer do
  @moduledoc """
  Idempotently imports the tracked real-publisher catalog dataset into Ash resources.

  ## Trusted writer confinement

  This module is the only trusted writer for the deterministic real-publisher
  corpus: every write runs with `authorize?: false`, so callers MUST pass
  datasets through `Hiraeth.RealCatalog.Validator` first (any finding blocks
  seeding). Callers are `priv/repo/seeds.exs`, Mix tasks, and ingestion phases
  that already validated.

  ## Two-phase bulk pipeline

  Each dataset import runs inside one `Ash.transact` (30-minute timeout) and is
  split into two phases:

  1. **Phase 1 (pure precompute):** every record is normalized into row maps
     keyed by natural identity per table (`publishers` slug, `imprints`
     `{publisher_slug, slug}`, `contributors`/`series`/`works`/`editions` slug,
     `identifiers` `{type, value}`, `contributions`
     `{contributor_slug, role, work_slug, edition_slug}`, `series_memberships`
     `{series_slug, work_slug}`, `cover_assets` `source_url`,
     `cover_assignments` `{edition_slug, source_url}`, `source_records`
     `{provider, source_type, source_uri, file_checksum}`). Rows never carry
     `:id` (Ash generates it; the attribute is not writable). Duplicate
     identity keys are deduped FIRST-WINS per dataset — this is load-bearing:
     intra-batch duplicates raise PG 21000 ("ON CONFLICT DO UPDATE command
     cannot affect row a second time") on PG16.

  2. **Phase 2 (bulk writes):** tables are upserted in FK order via
     `Ash.bulk_create` with `upsert?: true`, the per-resource `upsert_identity`,
     and `upsert_fields: {:replace, identity_keys}` — NEVER `:replace_all`,
     which would expand to `:id` and rewrite primary keys. AshPostgres executes
     this as true multi-row `insert_all ... ON CONFLICT` (PG16). The minimal
     conflict update leaves non-key metadata untouched; metadata mutation still
     flows through the per-row `Ash.update!`/`Ash.destroy!` sync/prune paths
     (`sync_work_metadata!` guarded by `source_safe_work_update?`,
     `sync_edition_metadata!`, cover-asset sync, contribution positions, stale
     prunes) but ONLY for rows that actually changed — zero per-row writes on a
     cold seed and on an unchanged reseed. After each parent upsert the
     process-dict cache entry is dropped and the id map is rebuilt from ONE
     `cached_read`. `import_runs` (identity includes `:id`) and
     `source_ledger_entries` are handled with Elixir-side diffs: the run is
     find-or-created on `provider` + `status == "applied"`, and ledger entries
     are bulk-created only for NEW source records.

  ## PG16 semantics note

  The corpus runs PostgreSQL 16, so upserts take the `ON CONFLICT DO UPDATE`
  path. PostgreSQL 17+ would route through `MERGE` when AshPostgres
  `:upsert_with_merge?` is enabled — do not assume the two are interchangeable;
  the pipeline was validated against PG16 (`server_version_num` 160014).
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

  alias Hiraeth.Covers
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.RealCatalog.{Dataset, ISBN, Slug, SourceIdentity, Validator}
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  require Ash.Query

  @import_cache_key {__MODULE__, :import_cache}
  @previous_source_work_cache_key {__MODULE__, :previous_source_work_cache}
  @provider_transaction_timeout :timer.minutes(30)
  @provider_transaction_resources [
    Contribution,
    Contributor,
    Edition,
    Identifier,
    Imprint,
    Publisher,
    Series,
    SeriesMembership,
    Work,
    CoverAsset,
    CoverAssignment,
    ImportRun,
    SourceLedgerEntry,
    SourceRecord
  ]

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
      Process.delete(@previous_source_work_cache_key)
    end
  end

  def seed_provider!(dataset, import_run, opts \\ []) do
    Process.put(@import_cache_key, %{})
    transaction_timeout = Keyword.get(opts, :transaction_timeout, @provider_transaction_timeout)
    prune_stale? = Keyword.get(opts, :prune_stale?, true)

    try do
      Ash.transact(
        @provider_transaction_resources,
        fn ->
          rows = build_dataset_rows!(dataset)
          write_bulk_dataset!(rows, dataset, import_run)

          if prune_stale? do
            prune_stale_source_records!(dataset.provider, dataset.file_checksum)
          end

          summary()
        end,
        timeout: transaction_timeout
      )
      |> case do
        {:ok, summary} -> {:ok, summary}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        {:error, e}
    after
      Process.delete(@import_cache_key)
      Process.delete(@previous_source_work_cache_key)
    end
  end

  defp import_dataset!(dataset, prune_stale?) do
    case Ash.transact(
           @provider_transaction_resources,
           fn -> transact_import!(dataset, prune_stale?) end,
           timeout: @provider_transaction_timeout
         ) do
      {:ok, result} -> result
      {:error, reason} -> raise reason
    end
  end

  defp transact_import!(dataset, prune_stale?) do
    import_run = ensure_import_run!(dataset)
    rows = build_dataset_rows!(dataset)
    write_bulk_dataset!(rows, dataset, import_run)

    if prune_stale? do
      prune_stale_source_records!(dataset.provider, dataset.file_checksum)
    end

    :ok
  end

  # --- Phase 1: pure precompute of per-table row maps -----------------------

  defp build_dataset_rows!(dataset) do
    initial = %{
      publishers: %{},
      imprints: %{},
      contributors: %{},
      series: %{},
      works: %{},
      editions: %{},
      identifiers: %{},
      contributions: %{},
      contribution_desired: %{},
      series_memberships: %{},
      cover_assets: %{},
      cover_assignments: %{},
      cover_state: %{},
      source_records: %{}
    }

    Enum.reduce(dataset.records, initial, fn record, acc ->
      accumulate_record_rows!(dataset, record, acc)
    end)
  end

  defp accumulate_record_rows!(dataset, record, acc) do
    publisher_slug = Slug.slugify(record.publisher)

    acc
    |> put_publisher_row(record, publisher_slug)
    |> put_imprint_row(record, publisher_slug)
    |> put_contributor_rows(record)
    |> put_series_rows(record, publisher_slug)
    |> put_work_row(record, publisher_slug)
    |> put_edition_row(record, publisher_slug)
    |> put_identifier_row(dataset, record)
    |> put_contribution_rows(record, publisher_slug)
    |> put_series_membership_rows(record, publisher_slug)
    |> put_cover_rows(record)
    |> put_source_record_row(dataset, record)
  end

  defp put_publisher_row(acc, record, publisher_slug) do
    update_in(
      acc.publishers,
      &Map.put_new(&1, publisher_slug, %{
        name: record.publisher,
        slug: publisher_slug
      })
    )
  end

  defp put_imprint_row(acc, record, publisher_slug) do
    if present?(record.imprint) do
      imprint_slug = Slug.slugify(record.imprint)

      update_in(
        acc.imprints,
        &Map.put_new(&1, {publisher_slug, imprint_slug}, %{
          name: record.imprint,
          slug: imprint_slug
        })
      )
    else
      acc
    end
  end

  defp put_contributor_rows(acc, record) do
    record.contributors
    |> Enum.uniq_by(fn contributor_data ->
      {Slug.slugify(contributor_data.name), contributor_data.role}
    end)
    |> Enum.reduce(acc, fn contributor_data, acc ->
      contributor_slug = Slug.slugify(contributor_data.name)

      update_in(
        acc.contributors,
        &Map.put_new(&1, contributor_slug, %{
          display_name: contributor_data.name,
          sort_name: contributor_data.name,
          slug: contributor_slug
        })
      )
    end)
  end

  defp put_series_rows(acc, record, publisher_slug) do
    record
    |> Map.get(:series, [])
    |> List.wrap()
    |> Enum.filter(&(present?(map_value(&1, :title)) and present?(map_value(&1, :slug))))
    |> Enum.reduce(acc, fn series_data, acc ->
      series_slug = map_value(series_data, :slug)

      update_in(
        acc.series,
        &Map.put_new(&1, series_slug, %{
          title: map_value(series_data, :title),
          slug: series_slug,
          publisher_slug: publisher_slug
        })
      )
    end)
  end

  defp put_work_row(acc, record, publisher_slug) do
    slug = work_slug(record, publisher_slug)

    update_in(acc.works, fn works ->
      case Map.fetch(works, slug) do
        {:ok, entry} ->
          Map.put(works, slug, %{entry | records: [record | entry.records]})

        :error ->
          Map.put(works, slug, %{attrs: work_attrs(record, slug), records: [record]})
      end
    end)
  end

  defp put_edition_row(acc, record, publisher_slug) do
    slug = edition_slug(record)

    update_in(acc.editions, fn editions ->
      case Map.fetch(editions, slug) do
        {:ok, entry} ->
          Map.put(editions, slug, %{entry | records: [record | entry.records]})

        :error ->
          Map.put(editions, slug, %{
            attrs: edition_create_attrs(record, publisher_slug),
            records: [record]
          })
      end
    end)
  end

  defp put_identifier_row(acc, dataset, record) do
    edition_slug = edition_slug(record)

    case normalized_isbn(record) do
      nil ->
        update_in(
          acc.identifiers,
          &Map.put_new(&1, {"source_record", source_identity(dataset, record)}, %{
            identifier_type: "source_record",
            value: source_identity(dataset, record),
            edition_slug: edition_slug
          })
        )

      isbn ->
        update_in(
          acc.identifiers,
          &Map.put_new(&1, {"isbn_13", isbn}, %{
            identifier_type: "isbn_13",
            value: isbn,
            edition_slug: edition_slug
          })
        )
    end
  end

  defp put_contribution_rows(acc, record, publisher_slug) do
    work_slug = work_slug(record, publisher_slug)
    edition_slug = edition_slug(record)

    desired =
      record.contributors
      |> Enum.uniq_by(fn contributor_data ->
        {Slug.slugify(contributor_data.name), contributor_data.role}
      end)
      |> Enum.with_index(1)
      |> Enum.map(fn {contributor_data, position} ->
        %{
          contributor_slug: Slug.slugify(contributor_data.name),
          role: contributor_data.role,
          work_slug: work_slug,
          edition_slug: edition_slug,
          position: position
        }
      end)

    acc =
      Enum.reduce(desired, acc, fn row, acc ->
        key = {row.contributor_slug, row.role, row.work_slug, row.edition_slug}

        update_in(acc.contributions, &Map.put_new(&1, key, row))
      end)

    # The last record of an edition owns the desired contributor set (the
    # per-record prune in the old pipeline ran last-wins too).
    desired_keys = Enum.map(desired, &{&1.contributor_slug, &1.role})

    update_in(acc.contribution_desired, &Map.put(&1, edition_slug, desired_keys))
  end

  defp put_series_membership_rows(acc, record, publisher_slug) do
    work_slug = work_slug(record, publisher_slug)

    record
    |> Map.get(:series, [])
    |> List.wrap()
    |> Enum.filter(&(present?(map_value(&1, :title)) and present?(map_value(&1, :slug))))
    |> Enum.reduce(acc, fn series_data, acc ->
      series_slug = map_value(series_data, :slug)

      update_in(
        acc.series_memberships,
        &Map.put_new(&1, {series_slug, work_slug}, %{
          position: map_value(series_data, :position),
          label: map_value(series_data, :label),
          series_slug: series_slug,
          work_slug: work_slug
        })
      )
    end)
  end

  defp put_cover_rows(acc, record) do
    edition_slug = edition_slug(record)

    if cover_source_url_present?(record) do
      put_cover_row(acc, edition_slug, Map.fetch!(record, :cover))
    else
      update_in(acc.cover_state, &Map.put(&1, edition_slug, nil))
    end
  end

  defp put_cover_row(acc, edition_slug, cover) do
    source_url = Map.fetch!(cover, :source_url)

    acc
    |> update_in([:cover_assets], fn assets ->
      case Map.fetch(assets, source_url) do
        {:ok, entry} ->
          Map.put(assets, source_url, %{entry | covers: [cover | entry.covers]})

        :error ->
          Map.put(assets, source_url, %{
            attrs: cover_asset_attrs(cover),
            covers: [cover]
          })
      end
    end)
    |> update_in(
      [:cover_assignments],
      &Map.put_new(&1, {edition_slug, source_url}, %{
        edition_slug: edition_slug,
        source_url: source_url
      })
    )
    # Last record of an edition owns its cover state (nil = no cover).
    |> update_in([:cover_state], &Map.put(&1, edition_slug, source_url))
  end

  defp put_source_record_row(acc, dataset, record) do
    checksum = dataset.file_checksum
    source_uri = edition_source_uri(record)
    key = {dataset.provider, "publisher_dataset", source_uri, checksum}

    update_in(
      acc.source_records,
      &Map.put_new(&1, key, %{
        provider: dataset.provider,
        source_type: "publisher_dataset",
        source_uri: source_uri,
        file_checksum: checksum,
        license_note: dataset.license_note,
        source_identity: source_identity(dataset, record),
        raw_payload: raw_payload(dataset, record),
        edition_slug: edition_slug(record),
        ledger_message:
          "Seeded public catalog metadata for #{record.edition.title} from #{dataset.provider}; raw payload is checksum-versioned and immutable."
      })
    )
  end

  defp edition_create_attrs(record, publisher_slug) do
    %{
      title: display_title(record, :edition),
      subtitle: record.edition.subtitle,
      slug: edition_slug(record),
      format: record.edition.format,
      language_code: Map.get(record.edition, :language_code),
      page_count: Map.get(record.edition, :page_count),
      height_mm: dimension_value(record, :height_mm),
      width_mm: dimension_value(record, :width_mm),
      depth_mm: dimension_value(record, :depth_mm),
      published_on: parse_date(Map.get(record.edition, :published_on)),
      work_slug: work_slug(record, publisher_slug),
      publisher_slug: publisher_slug,
      imprint_slug: if(present?(record.imprint), do: Slug.slugify(record.imprint), else: nil)
    }
  end

  # --- Phase 2: bulk writes in FK order (inside the dataset transaction) ----

  defp write_bulk_dataset!(rows, dataset, import_run) do
    publishers_by_slug = write_publishers!(rows.publishers)
    imprints_by_key = write_imprints!(rows.imprints, publishers_by_slug)
    contributors_by_slug = write_contributors!(rows.contributors)
    series_by_slug = write_series!(rows.series, publishers_by_slug)
    works_by_slug = write_works!(rows.works, dataset)

    editions_by_slug =
      write_editions!(rows.editions, publishers_by_slug, imprints_by_key, works_by_slug)

    write_identifiers!(rows.identifiers, editions_by_slug)

    write_contributions!(
      rows.contributions,
      rows.contribution_desired,
      contributors_by_slug,
      works_by_slug,
      editions_by_slug
    )

    write_series_memberships!(rows.series_memberships, series_by_slug, works_by_slug)
    assets_by_url = write_cover_assets!(rows.cover_assets)

    write_cover_assignments!(
      rows.cover_assignments,
      rows.cover_state,
      editions_by_slug,
      assets_by_url
    )

    write_source_records!(rows.source_records, import_run, editions_by_slug)
  end

  defp write_publishers!(publisher_rows) do
    bulk_upsert!(Publisher, Map.values(publisher_rows), :unique_slug, [:slug])
    id_map(Publisher, & &1.slug)
  end

  defp write_imprints!(imprint_rows, publishers_by_slug) do
    inputs =
      Enum.map(imprint_rows, fn {{publisher_slug, _slug}, row} ->
        Map.merge(row, %{publisher_id: Map.fetch!(publishers_by_slug, publisher_slug).id})
      end)

    bulk_upsert!(Imprint, inputs, :unique_publisher_slug, [:publisher_id, :slug])

    publisher_slug_by_id =
      Map.new(publishers_by_slug, fn {slug, publisher} -> {publisher.id, slug} end)

    Imprint
    |> refresh_cached_read()
    |> Map.new(fn imprint ->
      {{Map.fetch!(publisher_slug_by_id, imprint.publisher_id), imprint.slug}, imprint}
    end)
  end

  defp write_contributors!(contributor_rows) do
    bulk_upsert!(Contributor, Map.values(contributor_rows), :unique_slug, [:slug])
    id_map(Contributor, & &1.slug)
  end

  defp write_series!(series_rows, publishers_by_slug) do
    inputs =
      Enum.map(series_rows, fn {_slug, row} ->
        row
        |> Map.put(:publisher_id, Map.fetch!(publishers_by_slug, row.publisher_slug).id)
        |> Map.drop([:publisher_slug])
      end)

    bulk_upsert!(Series, inputs, :unique_slug, [:slug])
    id_map(Series, & &1.slug)
  end

  defp write_works!(work_entries, dataset) do
    inputs = Enum.map(work_entries, fn {_slug, %{attrs: attrs}} -> attrs end)
    bulk_upsert!(Work, inputs, :unique_slug, [:slug])
    works_by_slug = id_map(Work, & &1.slug)

    Enum.reduce(work_entries, works_by_slug, fn {slug, %{records: records}}, acc ->
      Enum.reduce(Enum.reverse(records), acc, fn record, acc ->
        work = Map.fetch!(acc, slug)
        updated = sync_work_metadata!(work, record, dataset.file_checksum, trusted_write_opts())
        Map.put(acc, slug, updated)
      end)
    end)
  end

  defp write_editions!(edition_entries, publishers_by_slug, imprints_by_key, works_by_slug) do
    inputs =
      Enum.map(edition_entries, fn {_slug, %{attrs: attrs}} ->
        %{
          title: attrs.title,
          subtitle: attrs.subtitle,
          slug: attrs.slug,
          format: attrs.format,
          language_code: attrs.language_code,
          page_count: attrs.page_count,
          height_mm: attrs.height_mm,
          width_mm: attrs.width_mm,
          depth_mm: attrs.depth_mm,
          published_on: attrs.published_on,
          work_id: Map.fetch!(works_by_slug, attrs.work_slug).id,
          publisher_id: Map.fetch!(publishers_by_slug, attrs.publisher_slug).id,
          imprint_id: resolve_imprint_id(attrs, imprints_by_key)
        }
      end)

    bulk_upsert!(Edition, inputs, :unique_slug, [:slug])
    editions_by_slug = id_map(Edition, & &1.slug)

    Enum.reduce(edition_entries, editions_by_slug, fn {slug, %{records: records}}, acc ->
      Enum.reduce(Enum.reverse(records), acc, fn record, acc ->
        sync_edition_for_record!(
          record,
          slug,
          acc,
          publishers_by_slug,
          imprints_by_key,
          works_by_slug
        )
      end)
    end)
  end

  defp sync_edition_for_record!(
         record,
         slug,
         editions_by_slug,
         publishers_by_slug,
         imprints_by_key,
         works_by_slug
       ) do
    edition = Map.fetch!(editions_by_slug, slug)
    publisher_slug = Slug.slugify(record.publisher)
    publisher = Map.fetch!(publishers_by_slug, publisher_slug)
    imprint = imprint_for_record(record, publisher_slug, imprints_by_key)
    work = Map.fetch!(works_by_slug, work_slug(record, publisher_slug))

    updated =
      sync_edition_metadata!(edition, record, work, publisher, imprint, trusted_write_opts())

    Map.put(editions_by_slug, slug, updated)
  end

  defp imprint_for_record(record, publisher_slug, imprints_by_key) do
    if present?(record.imprint) do
      Map.fetch!(imprints_by_key, {publisher_slug, Slug.slugify(record.imprint)})
    end
  end

  defp resolve_imprint_id(attrs, imprints_by_key) do
    if attrs.imprint_slug do
      Map.fetch!(imprints_by_key, {attrs.publisher_slug, attrs.imprint_slug}).id
    else
      nil
    end
  end

  defp write_identifiers!(identifier_rows, editions_by_slug) do
    inputs =
      Enum.map(identifier_rows, fn {{_type, _value}, row} ->
        %{
          identifier_type: row.identifier_type,
          value: row.value,
          edition_id: Map.fetch!(editions_by_slug, row.edition_slug).id
        }
      end)

    bulk_upsert!(Identifier, inputs, :unique_identifier, [:identifier_type, :value])
  end

  defp write_contributions!(
         contribution_rows,
         desired_by_edition,
         contributors_by_slug,
         works_by_slug,
         editions_by_slug
       ) do
    resolved =
      Enum.map(contribution_rows, fn {{contributor_slug, role, work_slug, edition_slug}, row} ->
        %{
          contributor_id: Map.fetch!(contributors_by_slug, contributor_slug).id,
          role: role,
          work_id: Map.fetch!(works_by_slug, work_slug).id,
          edition_id: Map.fetch!(editions_by_slug, edition_slug).id,
          position: row.position
        }
      end)

    Enum.each(resolved, &assert_contribution_identity_keys!/1)

    inputs =
      Enum.map(
        resolved,
        &Map.take(&1, [:contributor_id, :role, :work_id, :edition_id, :position])
      )

    bulk_upsert!(Contribution, inputs, :unique_contribution_slot, [
      :contributor_id,
      :role,
      :work_id,
      :edition_id
    ])

    prune_stale_contributions!(desired_by_edition, contributors_by_slug, editions_by_slug)

    contributions_by_key =
      Contribution
      |> cached_read()
      |> Map.new(fn contribution ->
        {{contribution.contributor_id, contribution.role, contribution.work_id,
          contribution.edition_id}, contribution}
      end)

    Enum.each(resolved, fn row ->
      case Map.get(
             contributions_by_key,
             {row.contributor_id, row.role, row.work_id, row.edition_id}
           ) do
        nil ->
          :ok

        contribution ->
          sync_contribution_position!(contribution, row.position, trusted_write_opts())
      end
    end)
  end

  defp assert_contribution_identity_keys!(row) do
    Enum.each([:contributor_id, :role, :work_id, :edition_id], fn key ->
      if is_nil(Map.get(row, key)) do
        raise "bulk import rejected a contribution row with nil #{key} " <>
                "(NULL identity keys are distinct on PG16 and would duplicate on reseed)"
      end
    end)
  end

  defp write_series_memberships!(membership_rows, series_by_slug, works_by_slug) do
    inputs =
      Enum.map(membership_rows, fn {{series_slug, work_slug}, row} ->
        %{
          series_id: Map.fetch!(series_by_slug, series_slug).id,
          work_id: Map.fetch!(works_by_slug, work_slug).id,
          position: row.position,
          label: row.label
        }
      end)

    bulk_upsert!(SeriesMembership, inputs, :unique_series_work, [:series_id, :work_id])
  end

  defp write_cover_assets!(asset_entries) do
    inputs = Enum.map(asset_entries, fn {_url, %{attrs: attrs}} -> attrs end)
    bulk_upsert!(CoverAsset, inputs, :unique_source_url, [:source_url])
    assets_by_url = id_map(CoverAsset, & &1.source_url)

    Enum.reduce(asset_entries, assets_by_url, fn {url, %{covers: covers}}, acc ->
      Enum.reduce(Enum.reverse(covers), acc, fn cover, acc ->
        asset = Map.fetch!(acc, url)
        updated = sync_cover_asset!(asset, cover, trusted_write_opts())
        Map.put(acc, url, updated)
      end)
    end)
  end

  defp write_cover_assignments!(assignment_rows, cover_state, editions_by_slug, assets_by_url) do
    inputs =
      Enum.map(assignment_rows, fn {{edition_slug, source_url}, _row} ->
        %{
          edition_id: Map.fetch!(editions_by_slug, edition_slug).id,
          cover_asset_id: Map.fetch!(assets_by_url, source_url).id,
          position: 1,
          visible?: true
        }
      end)

    bulk_upsert!(CoverAssignment, inputs, :unique_edition_cover, [:edition_id, :cover_asset_id])
    prune_stale_cover_assignments!(cover_state, editions_by_slug, assets_by_url)
  end

  defp write_source_records!(source_record_rows, import_run, editions_by_slug) do
    existing_keys =
      SourceRecord
      |> cached_read()
      |> MapSet.new(&{&1.provider, &1.source_type, &1.source_uri, &1.file_checksum})

    inputs =
      Enum.map(source_record_rows, fn {_key, row} ->
        %{
          provider: row.provider,
          source_type: row.source_type,
          source_uri: row.source_uri,
          file_checksum: row.file_checksum,
          license_note: row.license_note,
          source_identity: row.source_identity,
          raw_payload: row.raw_payload,
          imported_at: DateTime.utc_now(:second),
          import_run_id: import_run.id,
          edition_id: Map.fetch!(editions_by_slug, row.edition_slug).id
        }
      end)

    bulk_upsert!(SourceRecord, inputs, :unique_source_record, [
      :provider,
      :source_type,
      :source_uri,
      :file_checksum
    ])

    source_records_by_key =
      id_map(SourceRecord, &{&1.provider, &1.source_type, &1.source_uri, &1.file_checksum})

    # Ledger entries are Elixir-side diffs: only NEW source records (identity
    # keys absent before this dataset's upsert) get an entry, bulk-created
    # without upsert (the identity includes occurred_at and rows are never
    # re-created).
    new_rows =
      source_record_rows
      |> Enum.reject(fn {key, _row} -> MapSet.member?(existing_keys, key) end)

    ledger_inputs =
      Enum.map(new_rows, fn {key, row} ->
        %{
          source_record_id: Map.fetch!(source_records_by_key, key).id,
          event_type: "real_catalog_seeded",
          message: row.ledger_message,
          occurred_at: DateTime.utc_now(:second)
        }
      end)

    bulk_create!(SourceLedgerEntry, ledger_inputs)
  end

  # --- Bulk write primitives and id maps ------------------------------------

  defp bulk_upsert!(resource, inputs, identity, identity_keys) do
    if inputs == [] do
      :ok
    else
      result =
        Ash.bulk_create(inputs, resource, :create,
          upsert?: true,
          upsert_identity: identity,
          upsert_fields: {:replace, identity_keys},
          transaction: false,
          batch_size: 100,
          notify?: false,
          return_records?: false,
          return_errors?: true,
          stop_on_error?: false,
          authorize?: false
        )

      assert_bulk_success!(result, resource, "bulk upsert")
    end
  end

  defp bulk_create!(resource, inputs) do
    if inputs == [] do
      :ok
    else
      result =
        Ash.bulk_create(inputs, resource, :create,
          transaction: false,
          batch_size: 100,
          notify?: false,
          return_records?: false,
          return_errors?: true,
          stop_on_error?: false,
          authorize?: false
        )

      assert_bulk_success!(result, resource, "bulk create")
    end
  end

  defp assert_bulk_success!(%Ash.BulkResult{status: :success, error_count: 0}, _resource, _label) do
    :ok
  end

  defp assert_bulk_success!(%Ash.BulkResult{status: :error} = result, resource, label) do
    raise "#{label} failed for #{inspect(resource)}: #{inspect(result.errors, limit: 10)}"
  end

  defp id_map(resource, key_fun) do
    resource
    |> refresh_cached_read()
    |> Map.new(fn record -> {key_fun.(record), record} end)
  end

  defp refresh_cached_read(resource) do
    cache = Process.get(@import_cache_key, %{})
    Process.put(@import_cache_key, Map.delete(cache, resource))
    cached_read(resource)
  end

  # --- Per-row sync/prune (only for rows that actually changed) -------------

  defp prune_stale_contributions!(desired_by_edition, contributors_by_slug, editions_by_slug) do
    contributions = refresh_cached_read(Contribution)

    Enum.each(desired_by_edition, fn {edition_slug, desired_slug_keys} ->
      edition_id = Map.fetch!(editions_by_slug, edition_slug).id

      desired_ids =
        MapSet.new(desired_slug_keys, fn {contributor_slug, role} ->
          {Map.fetch!(contributors_by_slug, contributor_slug).id, role}
        end)

      contributions
      |> Enum.filter(&(&1.edition_id == edition_id))
      |> Enum.reject(&MapSet.member?(desired_ids, {&1.contributor_id, &1.role}))
      |> Enum.each(fn contribution ->
        Ash.destroy!(contribution, trusted_write_opts())
        uncache_record(contribution, Contribution)
      end)
    end)
  end

  defp prune_stale_cover_assignments!(cover_state, editions_by_slug, assets_by_url) do
    assignments = refresh_cached_read(CoverAssignment)

    Enum.each(cover_state, fn {edition_slug, desired_source_url} ->
      edition_id = Map.fetch!(editions_by_slug, edition_slug).id

      desired_cover_asset_id =
        if desired_source_url,
          do: Map.fetch!(assets_by_url, desired_source_url).id,
          else: nil

      assignments
      |> Enum.filter(&(&1.edition_id == edition_id))
      |> Enum.reject(&(&1.cover_asset_id == desired_cover_asset_id))
      |> Enum.each(fn assignment ->
        Ash.destroy!(assignment, trusted_write_opts())
        uncache_record(assignment, CoverAssignment)
      end)
    end)
  end

  # --- Kept helpers ----------------------------------------------------------

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
        values = compute_previous_source_work_values(current_file_checksum)

        Process.put(
          @previous_source_work_cache_key,
          Map.put(cache, current_file_checksum, values)
        )

        values
    end
  end

  defp compute_previous_source_work_values(current_file_checksum) do
    edition_work_ids = edition_work_id_map()

    SourceRecord
    |> cached_read()
    |> Enum.reject(&(&1.file_checksum == current_file_checksum))
    |> Enum.filter(&Map.has_key?(edition_work_ids, &1.edition_id))
    |> Enum.sort_by(&(&1.imported_at || ~U[0001-01-01 00:00:00Z]), {:desc, DateTime})
    |> Enum.reduce(%{}, &accumulate_previous_source_work_value(&1, &2, edition_work_ids))
  end

  defp edition_work_id_map do
    Edition
    |> cached_read()
    |> Map.new(&{&1.id, &1.work_id})
  end

  defp accumulate_previous_source_work_value(source_record, acc, edition_work_ids) do
    work_id = Map.fetch!(edition_work_ids, source_record.edition_id)
    payload = source_record.raw_payload || %{}

    meta_keys = [:description, :storefront_url, :editorial_praise]

    meta_keys
    |> Enum.reduce(acc, fn key, acc ->
      value = source_payload_value(payload, key)

      if blank_metadata?(value) do
        acc
      else
        Map.put_new(acc, {work_id, key}, value)
      end
    end)
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
      [provider, file_checksum],
      timeout: @provider_transaction_timeout
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
      [provider, file_checksum],
      timeout: @provider_transaction_timeout
    )

    Hiraeth.Repo.query!(
      """
      delete from source_records
      where provider = $1
        and source_type = 'publisher_dataset'
        and coalesce(file_checksum, '') <> $2
      """,
      [provider, file_checksum],
      timeout: @provider_transaction_timeout
    )

    :ok
  end

  defp cover_asset_attrs(cover) do
    Map.merge(base_cover_asset_attrs(cover), existing_cache_file_attrs(cover))
  end

  defp base_cover_asset_attrs(cover) do
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

  defp existing_cache_file_attrs(%{cache_policy: "cache_allowed"} = cover) do
    if cover.rights_basis == "local_cache_permitted" do
      cache_probe = %CoverAsset{source_url: cover.source_url}
      cached_path = Covers.cache_path(cache_probe)
      thumbnail_path = Covers.thumbnail_path(cache_probe)

      %{}
      |> put_existing_cache_path(:cached_file_path, cached_path)
      |> put_existing_cache_path(:thumbnail_file_path, thumbnail_path)
      |> maybe_put_cached_at()
    else
      %{}
    end
  end

  defp existing_cache_file_attrs(_cover), do: %{}

  defp put_existing_cache_path(attrs, key, path) do
    if File.regular?(path), do: Map.put(attrs, key, path), else: attrs
  end

  defp maybe_put_cached_at(%{cached_file_path: _cached_file_path} = attrs) do
    Map.put_new(attrs, :cached_at, DateTime.utc_now(:second))
  end

  defp maybe_put_cached_at(attrs), do: attrs

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
        Map.merge(updates, missing_existing_cache_file_attrs(asset, cover))
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

  defp missing_existing_cache_file_attrs(asset, cover) do
    cover
    |> existing_cache_file_attrs()
    |> Enum.reject(fn
      {:cached_file_path, _path} -> present?(asset.cached_file_path)
      {:thumbnail_file_path, _path} -> present?(asset.thumbnail_file_path)
      {:cached_at, _cached_at} -> not is_nil(asset.cached_at)
    end)
    |> Map.new()
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
      "ingestion_candidate" => ingestion_candidate_payload(dataset, record),
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

  defp ingestion_candidate_payload(dataset, record) do
    dataset
    |> Map.get(:ingestion_candidates_by_source_uri, %{})
    |> Map.get(edition_source_uri(record))
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

  defp source_identity(dataset, record), do: SourceIdentity.for_record(dataset.provider, record)

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
