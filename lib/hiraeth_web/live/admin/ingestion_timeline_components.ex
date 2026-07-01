defmodule HiraethWeb.Admin.IngestionTimelineComponents do
  @moduledoc false

  use HiraethWeb, :html

  import HiraethWeb.Admin.IngestionFormat

  attr :runs, :any, required: true
  attr :events_by_run, :map, required: true
  attr :snapshots_by_run, :map, required: true

  def run_timeline(assigns) do
    ~H"""
    <section id="admin-run-timeline-panel" class="qi-panel overflow-hidden">
      <div class="border-b qi-divider p-5">
        <p class="qi-label">Run timeline</p>
        <p class="mt-2 text-sm text-[var(--hiraeth-muted)]">
          Runs include counters, phase audit records, and retained source artifact pointers.
        </p>
      </div>

      <div id="admin-run-timeline" phx-update="stream" class="divide-y divide-[var(--hiraeth-line)]">
        <article id="admin-run-empty" class="hidden only:block p-6">
          <div class="qi-empty p-5 text-sm text-[var(--hiraeth-muted)]">
            No runs have been recorded for this provider.
          </div>
        </article>
        <article :for={{dom_id, run} <- @runs} id={dom_id} class="space-y-4 p-5">
          <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
            <div class="min-w-0 space-y-1">
              <h3
                id={"admin-run-title-#{run.id}"}
                class="break-all font-mono text-sm font-semibold text-[var(--hiraeth-ink)]"
              >
                {run.run_key}
              </h3>
              <p class="text-xs text-[var(--hiraeth-muted)]">
                Requested by {run.requested_by || "unknown"} · started {format_datetime(
                  run.started_at || run.inserted_at
                )}
              </p>
            </div>
            <span class={event_badge_class(run.status)}>{run.status}</span>
          </div>

          <dl
            id={"admin-run-counts-#{run.id}"}
            class="grid gap-3 text-xs sm:grid-cols-3 lg:grid-cols-6"
          >
            <.run_count label="Sources" value={run.source_count} />
            <.run_count label="Snapshots" value={run.snapshot_count} />
            <.run_count label="Candidates" value={run.candidate_count} />
            <.run_count label="Accepted" value={run.accepted_count} />
            <.run_count label="Rejected" value={run.rejected_count} />
            <.run_count label="Errors" value={run.error_count} />
          </dl>

          <.run_events_panel run={run} events={run_events(@events_by_run, run.id)} />
          <.run_artifacts_panel run={run} artifacts={run_artifacts(@snapshots_by_run, run.id)} />
        </article>
      </div>
    </section>
    """
  end

  attr :artifact, :any, default: nil

  def artifact_detail_panel(assigns) do
    ~H"""
    <section :if={@artifact} id="admin-artifact-detail" class="qi-panel space-y-4 p-6">
      <div class="border-b qi-divider pb-4">
        <p class="qi-label">Artifact detail</p>
        <h2 class="mt-2 break-all font-mono text-sm font-semibold text-[var(--hiraeth-ink)]">
          {artifact_pointer(@artifact)}
        </h2>
      </div>
      <dl class="grid gap-4 text-sm md:grid-cols-2">
        <.artifact_detail_item label="Source URI" value={@artifact.source_uri} />
        <.artifact_detail_item label="Content checksum" value={@artifact.content_checksum} />
        <.artifact_detail_item label="Content type" value={@artifact.content_type || "Not recorded"} />
        <.artifact_detail_item label="Retained bytes" value={format_bytes(@artifact.byte_size)} />
      </dl>
      <p class="text-xs leading-5 text-[var(--hiraeth-muted)]">
        Raw bytes remain in the private retention root. This admin detail route exposes the retained pointer and audit metadata without serving private files from public static paths.
      </p>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp run_count(assigns) do
    ~H"""
    <div class="border border-[var(--hiraeth-line)] bg-[var(--hiraeth-warm)] p-3">
      <dt class="font-mono text-[10px] uppercase tracking-[0.16em] text-[var(--hiraeth-label)]">
        {@label}
      </dt>
      <dd class="mt-1 font-mono text-base text-[var(--hiraeth-ink)]">{@value}</dd>
    </div>
    """
  end

  attr :run, :any, required: true
  attr :events, :list, required: true

  defp run_events_panel(assigns) do
    ~H"""
    <div id={"admin-run-events-#{@run.id}"} class="space-y-2">
      <p class="qi-label">Audit events</p>
      <div :if={@events == []} class="qi-empty p-3 text-xs text-[var(--hiraeth-muted)]">
        No events yet.
      </div>
      <ol class="space-y-2">
        <li
          :for={event <- @events}
          id={"admin-event-#{event.id}"}
          class="grid gap-2 border-l-2 border-[var(--hiraeth-thread)] bg-[var(--hiraeth-warm)] p-3 text-xs md:grid-cols-[9rem_minmax(0,1fr)_auto]"
        >
          <time class="font-mono text-[var(--hiraeth-label)]">{format_datetime(event.occurred_at)}</time>
          <div class="min-w-0">
            <p class="font-mono font-semibold text-[var(--hiraeth-ink)]">{event.event_kind}</p>
            <p class="mt-1 text-[var(--hiraeth-muted)]">{event.message || "No message recorded."}</p>
          </div>
          <span class={event_badge_class(event.status)}>{event.status}</span>
        </li>
      </ol>
    </div>
    """
  end

  attr :run, :any, required: true
  attr :artifacts, :list, required: true

  defp run_artifacts_panel(assigns) do
    ~H"""
    <div id={"admin-run-artifacts-#{@run.id}"} class="space-y-2">
      <p class="qi-label">Audit artifacts</p>
      <div :if={@artifacts == []} class="qi-empty p-3 text-xs text-[var(--hiraeth-muted)]">
        No retained artifacts yet.
      </div>
      <ul class="space-y-2">
        <li
          :for={snapshot <- @artifacts}
          id={"admin-artifact-#{snapshot.id}"}
          class="flex flex-col gap-2 border border-[var(--hiraeth-line)] p-3 text-xs md:flex-row md:items-center md:justify-between"
        >
          <div class="min-w-0">
            <.artifact_pointer_link snapshot={snapshot} />
            <p class="mt-1 break-all text-[var(--hiraeth-muted)]">{snapshot.source_uri}</p>
          </div>
          <span class="font-mono text-[var(--hiraeth-label)]">{format_bytes(snapshot.byte_size)}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :snapshot, :any, required: true

  defp artifact_pointer_link(assigns) do
    ~H"""
    <.link
      :if={artifact_linkable?(@snapshot)}
      id={"admin-artifact-link-#{@snapshot.id}"}
      patch={~p"/admin/ingestion/artifacts/#{@snapshot.id}"}
      class="qi-action-link break-all font-mono font-semibold"
    >
      {artifact_pointer(@snapshot)}
    </.link>
    <span
      :if={!artifact_linkable?(@snapshot)}
      id={"admin-artifact-unavailable-#{@snapshot.id}"}
      class="break-all font-mono font-semibold text-[var(--hiraeth-muted)]"
      aria-disabled="true"
    >
      Artifact pointer unavailable
    </span>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp artifact_detail_item(assigns) do
    ~H"""
    <div class="border-t qi-divider pt-3">
      <dt class="qi-label">{@label}</dt>
      <dd class="mt-2 break-all text-[var(--hiraeth-muted)]">{@value}</dd>
    </div>
    """
  end
end
