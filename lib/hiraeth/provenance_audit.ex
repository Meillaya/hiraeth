defmodule Hiraeth.ProvenanceAudit do
  @moduledoc """
  Exports provenance completeness evidence for public metadata and covers.

  This module is intentionally a data-completeness gate. It records source,
  license, rights, and takedown facts; it does not make legal conclusions.
  """

  alias Hiraeth.Audit.AuditEvent
  alias Hiraeth.Covers
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  @default_output_dir "artifacts/qa/provenance"

  def run!(opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    fail_on_error? = Keyword.get(opts, :fail_on_error?, true)
    audit = audit!()

    File.mkdir_p!(output_dir)

    File.write!(
      Path.join(output_dir, "source-ledger.csv"),
      source_ledger_csv(audit.source_ledger)
    )

    File.write!(Path.join(output_dir, "takedown-audit.csv"), takedown_csv(audit.takedown_audit))

    File.write!(
      Path.join(output_dir, "cover-cache-audit.csv"),
      cover_cache_csv(audit.cover_cache_audit)
    )

    File.write!(
      Path.join(output_dir, "audit-provenance.json"),
      Jason.encode!(audit, pretty: true)
    )

    if fail_on_error? and failed?(audit) do
      raise "provenance audit failed: #{failure_summary(audit)}"
    end

    audit
  end

  def audit! do
    source_records = Ash.read!(SourceRecord, authorize?: false)
    ledger_entries = Ash.read!(SourceLedgerEntry, authorize?: false)

    cover_assignments =
      CoverAssignment |> Ash.read!(authorize?: false) |> Ash.load!([:cover_asset, :edition])

    cover_assets = Ash.read!(CoverAsset, authorize?: false)
    audit_events = Ash.read!(AuditEvent, authorize?: false)

    source_ledger = Enum.flat_map(source_records, &source_rows/1)

    source_record_ids_with_ledger =
      ledger_entries |> Enum.map(& &1.source_record_id) |> MapSet.new()

    %{
      source_records: length(source_records),
      source_ledger_rows: length(source_ledger),
      source_ledger: source_ledger,
      missing_provenance: missing_source_provenance(source_records, source_ledger),
      source_ledger_missing: source_ledger_missing(source_records, source_record_ids_with_ledger),
      invalid_public_covers: invalid_public_covers(cover_assignments),
      cover_cache_audit: cover_cache_audit(cover_assets),
      takedown_audit: takedown_audit(cover_assets, cover_assignments, audit_events),
      audit_events: audit_event_rows(audit_events),
      long_copied_text: copied_text_findings(source_records)
    }
  end

  defp failed?(audit) do
    Enum.any?(
      [
        audit.missing_provenance,
        audit.source_ledger_missing,
        audit.invalid_public_covers,
        audit.long_copied_text
      ],
      &(&1 != [])
    )
  end

  defp failure_summary(audit) do
    [
      missing_provenance: length(audit.missing_provenance),
      source_ledger_missing: length(audit.source_ledger_missing),
      invalid_public_covers: length(audit.invalid_public_covers),
      long_copied_text: length(audit.long_copied_text)
    ]
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp source_rows(%SourceRecord{} = source_record) do
    payload = source_record.raw_payload || %{}

    source_record
    |> displayed_fields()
    |> Enum.map(fn field ->
      value = payload_value(payload, field)
      field_source = field_source(payload, field)

      %{
        entity: entity_from_source_uri(source_record.source_uri),
        field: field,
        value_hash: value_hash(value),
        source_record_id: source_record.id,
        source_uri: source_record.source_uri,
        provider: source_record.provider,
        source_type: source_record.source_type,
        license_or_rights_basis:
          field_source["rights_basis"] || field_source["license_note"] ||
            source_record.license_note,
        provenance_source_uri: field_source["source_uri"] || source_record.source_uri,
        provenance_provider: field_source["provider"] || source_record.provider,
        provenance_source_type: field_source["source_type"] || source_record.source_type,
        import_run_id: source_record.import_run_id,
        imported_at: source_record.imported_at && DateTime.to_iso8601(source_record.imported_at)
      }
    end)
  end

  defp displayed_fields(%SourceRecord{raw_payload: payload}) when is_map(payload) do
    fields =
      case payload["displayed_fields"] do
        displayed when is_list(displayed) and displayed != [] ->
          displayed

        _ ->
          payload
          |> Map.keys()
          |> Enum.reject(
            &(&1 in [
                "displayed_fields",
                "field_sources",
                "provider_permissions",
                "fixture_note",
                "provenance"
              ])
          )
      end

    field_source_fields =
      case payload["field_sources"] do
        field_sources when is_map(field_sources) -> Map.keys(field_sources)
        _ -> []
      end

    fields
    |> Kernel.++(field_source_fields)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp displayed_fields(_source_record), do: []

  defp field_source(payload, field) do
    case get_in(payload, ["field_sources", field]) do
      field_source when is_map(field_source) -> field_source
      _ -> %{}
    end
  end

  defp payload_value(payload, field) do
    value =
      field
      |> String.split(".")
      |> Enum.reduce(payload, fn key, acc ->
        case acc do
          %{} -> Map.get(acc, key)
          _ -> nil
        end
      end)

    if is_nil(value), do: payload_value_fallback(payload, field), else: value
  end

  defp payload_value_fallback(payload, field)
       when field in ["title", "subtitle", "format", "published_on", "isbn_13"] do
    get_in(payload, ["edition", field]) || get_in(payload, ["work", field])
  end

  defp payload_value_fallback(payload, "source_url"), do: get_in(payload, ["cover", "source_url"])
  defp payload_value_fallback(_payload, _field), do: nil

  defp entity_from_source_uri(source_uri) when is_binary(source_uri) do
    case String.split(source_uri, ":edition:", parts: 2) do
      [_prefix, slug] -> "edition:#{slug}"
      _ -> source_uri
    end
  end

  defp entity_from_source_uri(_source_uri), do: "unknown"

  defp missing_source_provenance(source_records, source_ledger) do
    source_record_rows = Enum.group_by(source_ledger, & &1.source_record_id)

    source_records
    |> Enum.flat_map(fn source_record ->
      []
      |> maybe_add_blank(source_record.provider, source_record.source_uri, "provider is missing")
      |> maybe_add_blank(
        source_record.source_uri,
        source_record.source_uri,
        "source URI is missing"
      )
      |> maybe_add_blank(
        source_record.license_note,
        source_record.source_uri,
        "license note is missing"
      )
      |> maybe_add_no_rows(source_record, source_record_rows)
    end)
  end

  defp maybe_add_blank(findings, value, source_uri, reason) do
    if present?(value), do: findings, else: [%{source_uri: source_uri, reason: reason} | findings]
  end

  defp maybe_add_no_rows(findings, source_record, source_record_rows) do
    if Map.get(source_record_rows, source_record.id, []) == [] do
      [%{source_uri: source_record.source_uri, reason: "no displayed fields exported"} | findings]
    else
      findings
    end
  end

  defp source_ledger_missing(source_records, source_record_ids_with_ledger) do
    source_records
    |> Enum.reject(&MapSet.member?(source_record_ids_with_ledger, &1.id))
    |> Enum.map(&%{source_record_id: &1.id, source_uri: &1.source_uri})
  end

  defp invalid_public_covers(cover_assignments) do
    cover_assignments
    |> Enum.filter(& &1.visible?)
    |> Enum.reject(&valid_public_cover?/1)
    |> Enum.map(fn assignment ->
      asset = loaded_or_nil(assignment.cover_asset)

      %{
        cover_assignment_id: assignment.id,
        cover_asset_id: assignment.cover_asset_id,
        edition_id: assignment.edition_id,
        reason: invalid_cover_reason(asset)
      }
    end)
  end

  defp valid_public_cover?(%CoverAssignment{} = assignment) do
    case loaded_or_nil(assignment.cover_asset) do
      %CoverAsset{} = asset ->
        Covers.public_cover_provenance_valid?(asset)

      _ ->
        false
    end
  end

  defp invalid_cover_reason(nil), do: "cover assignment has no cover asset"

  defp invalid_cover_reason(%CoverAsset{} = asset) do
    cond do
      true -> Covers.public_cover_rejection_reason(asset)
    end
  end

  defp takedown_audit(cover_assets, cover_assignments, audit_events) do
    assignments_by_asset = Enum.group_by(cover_assignments, & &1.cover_asset_id)
    events_by_asset = audit_events |> audit_event_rows() |> Enum.group_by(& &1.entity_id)

    cover_assets
    |> Enum.filter(&(&1.takedown_state != "visible"))
    |> Enum.map(fn asset ->
      asset_events = Map.get(events_by_asset, asset.id, [])

      %{
        cover_asset_id: asset.id,
        takedown_state: asset.takedown_state,
        provider: asset.provider,
        source_url_hash: value_hash(asset.source_url),
        assignment_ids:
          asset
          |> Map.get(:id)
          |> then(&Map.get(assignments_by_asset, &1, []))
          |> Enum.map(fn assignment -> assignment.id end),
        audit_event_reasons:
          asset_events
          |> Enum.map(&get_in(&1.metadata, ["reason"]))
          |> Enum.reject(&is_nil/1)
      }
    end)
  end

  defp cover_cache_audit(cover_assets) do
    Enum.map(cover_assets, fn asset ->
      %{
        cover_asset_id: asset.id,
        provider: asset.provider,
        cache_policy: asset.cache_policy,
        cache_decision: cover_cache_decision(asset),
        rights_basis: asset.rights_basis,
        source_url_hash: value_hash(asset.source_url),
        cached_file_path: asset.cached_file_path,
        thumbnail_file_path: asset.thumbnail_file_path,
        cached_at: asset.cached_at && DateTime.to_iso8601(asset.cached_at),
        public?: Covers.public_cover_asset?(asset),
        provenance_valid?: Covers.public_cover_provenance_valid?(asset),
        rejection_reason:
          if(Covers.public_cover_provenance_valid?(asset),
            do: nil,
            else: Covers.public_cover_rejection_reason(asset)
          )
      }
    end)
  end

  defp cover_cache_decision(%CoverAsset{cache_policy: "cache_allowed"} = asset) do
    if present?(asset.cached_file_path), do: "cached_public_cover", else: "cache_allowed_pending"
  end

  defp cover_cache_decision(%CoverAsset{cache_policy: "link_only"} = asset) do
    if present?(asset.cached_file_path) or present?(asset.thumbnail_file_path),
      do: "invalid_link_only_cache",
      else: "remote_link_only"
  end

  defp cover_cache_decision(_asset), do: "invalid_cover_cache_policy"

  defp audit_event_rows(audit_events) do
    audit_events
    |> Enum.filter(
      &(String.contains?(&1.event_type || "", "takedown") or &1.entity_type == "cover_asset")
    )
    |> Enum.map(fn event ->
      %{
        id: event.id,
        event_type: event.event_type,
        entity_type: event.entity_type,
        entity_id: event.entity_id,
        metadata: event.metadata || %{},
        occurred_at: event.occurred_at && DateTime.to_iso8601(event.occurred_at)
      }
    end)
  end

  defp copied_text_findings(source_records) do
    source_records
    |> Enum.flat_map(&payload_strings(&1.raw_payload))
    |> Enum.filter(&(String.length(&1) > 280))
  end

  defp payload_strings(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&payload_strings/1)

  defp payload_strings(value) when is_list(value), do: Enum.flat_map(value, &payload_strings/1)
  defp payload_strings(value) when is_binary(value), do: [value]
  defp payload_strings(_value), do: []

  defp source_ledger_csv(rows) do
    header = [
      "entity",
      "field",
      "value_hash",
      "source_record_id",
      "source_uri",
      "provider",
      "source_type",
      "license_or_rights_basis",
      "import_run_id",
      "imported_at",
      "provenance_source_uri",
      "provenance_provider",
      "provenance_source_type"
    ]

    csv(header, rows, fn row ->
      [
        row.entity,
        row.field,
        row.value_hash,
        row.source_record_id,
        row.source_uri,
        row.provider,
        row.source_type,
        row.license_or_rights_basis,
        row.import_run_id,
        row.imported_at,
        row.provenance_source_uri,
        row.provenance_provider,
        row.provenance_source_type
      ]
    end)
  end

  defp cover_cache_csv(rows) do
    header = [
      "cover_asset_id",
      "provider",
      "cache_policy",
      "cache_decision",
      "rights_basis",
      "source_url_hash",
      "cached_file_path",
      "thumbnail_file_path",
      "cached_at",
      "public?",
      "provenance_valid?",
      "rejection_reason"
    ]

    csv(header, rows, fn row ->
      [
        row.cover_asset_id,
        row.provider,
        row.cache_policy,
        row.cache_decision,
        row.rights_basis,
        row.source_url_hash,
        row.cached_file_path,
        row.thumbnail_file_path,
        row.cached_at,
        row.public?,
        row.provenance_valid?,
        row.rejection_reason
      ]
    end)
  end

  defp takedown_csv(rows) do
    header = [
      "cover_asset_id",
      "takedown_state",
      "provider",
      "source_url_hash",
      "assignment_ids",
      "audit_event_reasons"
    ]

    csv(header, rows, fn row ->
      [
        row.cover_asset_id,
        row.takedown_state,
        row.provider,
        row.source_url_hash,
        Enum.join(row.assignment_ids, ";"),
        Enum.join(row.audit_event_reasons, ";")
      ]
    end)
  end

  defp csv(header, rows, row_fun) do
    ([header] ++ Enum.map(rows, row_fun))
    |> Enum.map_join("\n", fn row -> row |> Enum.map(&escape_csv/1) |> Enum.join(",") end)
    |> Kernel.<>("\n")
  end

  defp escape_csv(value) do
    value = to_string(value || "")

    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp value_hash(value) do
    :crypto.hash(:sha256, hashable_value(value)) |> Base.encode16(case: :lower)
  end

  defp hashable_value(nil), do: ""
  defp hashable_value(value) when is_binary(value), do: value
  defp hashable_value(value) when is_boolean(value) or is_number(value), do: to_string(value)

  defp hashable_value(value) do
    value
    |> normalize_for_hash()
    |> inspect(charlists: :as_lists, limit: :infinity, printable_limit: :infinity)
  end

  defp normalize_for_hash(%_struct{} = struct),
    do: struct |> Map.from_struct() |> normalize_for_hash()

  defp normalize_for_hash(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_for_hash(value)} end)
  end

  defp normalize_for_hash(list) when is_list(list), do: Enum.map(list, &normalize_for_hash/1)
  defp normalize_for_hash(value), do: value

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp loaded_or_nil(%Ash.NotLoaded{}), do: nil
  defp loaded_or_nil(value), do: value
end
