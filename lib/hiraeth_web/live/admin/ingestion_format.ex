defmodule HiraethWeb.Admin.IngestionFormat do
  @moduledoc false

  alias Hiraeth.Ingestion.SourceSnapshot

  def status_badge_class(true), do: badge_class("succeeded")
  def status_badge_class(false), do: badge_class("warning")

  def event_badge_class(status), do: badge_class(status)

  def badge_class(status) do
    base =
      "inline-flex items-center border px-2 py-1 font-mono text-[10px] font-semibold uppercase tracking-[0.16em]"

    colors =
      case status do
        status when status in ["succeeded", "enabled", true] ->
          "border-[var(--hiraeth-line-strong)] bg-[var(--hiraeth-surface)] text-[var(--hiraeth-ink)]"

        status when status in ["failed", "cancelled"] ->
          "border-[var(--hiraeth-error-muted)] bg-[var(--hiraeth-error-bg)] text-[var(--hiraeth-error-ink)]"

        status when status in ["running", "queued", "planned"] ->
          "border-[var(--hiraeth-line-strong)] bg-[var(--hiraeth-warm)] text-[var(--hiraeth-ink)]"

        _other ->
          "border-[var(--hiraeth-thread)] bg-[var(--hiraeth-thread-soft)] text-[var(--hiraeth-thread)]"
      end

    [base, colors]
  end

  def hosts_text([]), do: "No host allowlist recorded"
  def hosts_text(hosts) when is_list(hosts), do: Enum.join(hosts, ", ")
  def hosts_text(_hosts), do: "No host allowlist recorded"

  def limit_text(nil, _unit), do: "No limit recorded"
  def limit_text(value, unit), do: "#{value} #{unit}"

  def run_events(events_by_run, run_id), do: Map.get(events_by_run, run_id, [])
  def run_artifacts(snapshots_by_run, run_id), do: Map.get(snapshots_by_run, run_id, [])

  def format_bytes(nil), do: "unknown size"
  def format_bytes(bytes), do: "#{bytes} bytes"

  def format_datetime(nil), do: "not recorded"

  def format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  def format_datetime(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime()
  end

  def dom_id(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  def artifact_pointer(snapshot) do
    first_present([snapshot.artifact_path, snapshot.storage_ref])
  end

  def artifact_linkable?(snapshot) do
    case artifact_pointer(snapshot) do
      pointer when is_binary(pointer) ->
        match?({:ok, _path}, SourceSnapshot.validate_relative_artifact_path(pointer))

      _other ->
        false
    end
  end

  defp first_present(values) do
    Enum.find(values, &(&1 not in [nil, ""]))
  end
end
