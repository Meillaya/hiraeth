defmodule Hiraeth.RealCatalog.Importer do
  @moduledoc """
  Idempotently imports the tracked real-publisher catalog dataset into Ash resources.
  """

  alias Hiraeth.Catalog.{Contribution, Contributor, Edition, Identifier, Imprint, Publisher, Work}
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.RealCatalog.{Dataset, ISBN, Slug, Validator}
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  def seed!(dir \\ Dataset.default_dir()) do
    with {:ok, datasets} <- Dataset.load_dir(dir),
         {:ok, _summary} <- Validator.validate_datasets(datasets) do
      Enum.each(datasets, &import_dataset!/1)
      {:ok, summary()}
    end
  end

  defp import_dataset!(dataset) do
    import_run = ensure_import_run!(dataset)
    Enum.each(dataset.records, &import_record!(dataset, &1, import_run))
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
      |> sync_work_metadata!(record, trusted_write_opts())

    edition = find_or_create_edition!(record, publisher, imprint, work)
    ensure_identifier!(edition, normalized_isbn!(record), trusted_write_opts())
    ensure_contributions!(record, work, edition, trusted_write_opts())
    ensure_cover!(record, edition, trusted_write_opts())
    ensure_source_record!(dataset, record, import_run, trusted_write_opts())
  end

  defp work_attrs(record, work_slug) do
    %{
      title: record.work.title,
      subtitle: record.work.subtitle,
      slug: work_slug,
      publication_state: record.work.publication_state || "published"
    }
    |> Map.merge(work_metadata_attrs(record))
  end

  defp sync_work_metadata!(work, record, write_opts) do
    updates =
      record
      |> work_metadata_attrs()
      |> Enum.reject(fn {key, value} ->
        blank_metadata?(value) or not blank_metadata?(Map.get(work, key))
      end)
      |> Map.new()

    if updates == %{} do
      work
    else
      work
      |> Ash.Changeset.for_update(:update, updates)
      |> Ash.update!(write_opts)
    end
  end

  defp work_metadata_attrs(record) do
    %{}
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

  defp maybe_put_metadata(map, _key, value) when value in [nil, "", []], do: map

  defp maybe_put_metadata(map, key, value) when is_binary(value),
    do: Map.put(map, key, String.trim(value))

  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp blank_metadata?(value), do: value in [nil, "", []]

  defp find_or_create_edition!(record, publisher, imprint, work) do
    isbn = normalized_isbn!(record)

    existing =
      Identifier
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.identifier_type == "isbn_13" and &1.value == isbn))

    if existing do
      Edition
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.id == existing.edition_id))
    else
      attrs = %{
        title: record.edition.title,
        subtitle: record.edition.subtitle,
        slug: edition_slug(record),
        format: record.edition.format,
        published_on: parse_date(record.edition.published_on),
        work_id: work.id,
        publisher_id: publisher.id,
        imprint_id: if(imprint, do: imprint.id, else: nil)
      }

      Edition
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!(trusted_write_opts())
    end
  end

  defp ensure_identifier!(edition, isbn, write_opts) do
    find_or_create_by!(
      Identifier,
      &(&1.identifier_type == "isbn_13" and &1.value == isbn),
      %{identifier_type: "isbn_13", value: isbn, edition_id: edition.id},
      write_opts
    )
  end

  defp ensure_contributions!(record, work, edition, write_opts) do
    record.contributors
    |> Enum.with_index(1)
    |> Enum.each(fn {contributor_data, position} ->
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

      find_or_create_by!(
        Contribution,
        &(&1.edition_id == edition.id and &1.contributor_id == contributor.id and
            &1.role == contributor_data.role),
        %{
          contributor_id: contributor.id,
          edition_id: edition.id,
          work_id: work.id,
          role: contributor_data.role,
          position: position
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
    end
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

  defp ensure_source_record!(dataset, record, import_run, write_opts) do
    checksum = dataset.file_checksum
    source_uri = edition_source_uri(record)

    source_record =
      find_or_create_by!(
        SourceRecord,
        &(&1.provider == dataset.provider and &1.source_type == "publisher_dataset" and
            &1.source_uri == source_uri and &1.file_checksum == checksum),
        %{
          provider: dataset.provider,
          source_type: "publisher_dataset",
          source_uri: source_uri,
          file_checksum: checksum,
          license_note: dataset.license_note,
          raw_payload: raw_payload(dataset, record),
          imported_at: DateTime.utc_now(:second),
          import_run_id: import_run.id
        },
        write_opts
      )

    ensure_source_ledger_entry!(source_record, record, write_opts)
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
      "source_sku" => record.source_sku,
      "displayed_fields" => record.displayed_fields,
      "publisher" => record.publisher,
      "imprint" => record.imprint,
      "work" => Map.take(record.work, [:title, :subtitle, :original_title, :publication_state]),
      "edition" =>
        record.edition
        |> Map.take([:title, :subtitle, :format, :published_on, :isbn_13])
        |> Map.put(:isbn_13, normalized_isbn!(record)),
      "contributors" => Enum.map(record.contributors, &Map.take(&1, [:name, :role])),
      "curation" => Map.take(record.curation, [:status, :notes])
    }
    |> maybe_put_payload_value("description", prose_description(record))
    |> maybe_put_payload_value("storefront_url", Map.get(record, :storefront_url))
    |> maybe_put_payload_value("editorial_praise", editorial_praise(record))
    |> maybe_put_cover_payload(record)
    |> maybe_put_no_cover_reason(record)
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
    |> Ash.read!(authorize?: false)
    |> Enum.find(predicate) ||
      resource
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!(write_opts)
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
    do: "#{publisher_slug}-#{Slug.slugify(record.work.title)}"

  defp edition_slug(record),
    do:
      "#{Slug.slugify(record.publisher)}-#{Slug.slugify(record.edition.title)}-#{record.edition.format}-#{normalized_isbn!(record)}"

  defp edition_source_uri(record), do: "#{record.source_uri}#isbn-#{normalized_isbn!(record)}"

  defp normalized_isbn!(record), do: ISBN.normalize!(record.edition.isbn_13)

  defp trusted_write_opts, do: [authorize?: false]

  defp cover_source_url_present?(%{cover: cover}) when is_map(cover),
    do: present?(Map.get(cover, :source_url))

  defp cover_source_url_present?(_record), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
