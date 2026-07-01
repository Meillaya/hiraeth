defmodule HiraethWeb.Admin.QuarantineComponents do
  @moduledoc false

  use HiraethWeb, :html

  import HiraethWeb.Admin.IngestionFormat

  alias Hiraeth.Ingestion.RecordCandidate

  attr :counts, :map, required: true

  def quarantine_summary(assigns) do
    ~H"""
    <section id="admin-quarantine-summary" class="grid gap-4 md:grid-cols-3">
      <.metric id="admin-quarantine-total" label="Candidates" value={@counts.total} />
      <.metric id="admin-quarantine-pending" label="Pending" value={@counts.pending} />
      <.metric id="admin-quarantine-destructive" label="Destructive" value={@counts.destructive} />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp metric(assigns) do
    ~H"""
    <div id={@id} class="qi-panel p-4">
      <p class="qi-label">{@label}</p>
      <p class="mt-2 font-serif text-3xl text-[var(--hiraeth-ink)]">{@value}</p>
    </div>
    """
  end

  attr :runs, :any, required: true
  attr :selected_run, :any, default: nil
  attr :can_mutate?, :boolean, default: false

  def run_control_panel(assigns) do
    ~H"""
    <section id="admin-run-control-panel" class="qi-panel overflow-hidden">
      <div class="border-b qi-divider p-5">
        <p class="qi-label">Run controls</p>
        <p class="mt-2 text-sm text-[var(--hiraeth-muted)]">
          Retry failed runs, replay retained snapshots, cancel active runs, or export audit evidence.
        </p>
      </div>
      <div
        id="admin-quarantine-runs"
        phx-update="stream"
        class="divide-y divide-[var(--hiraeth-line)]"
      >
        <article id="admin-quarantine-runs-empty" class="hidden only:block p-5">
          <div class="qi-empty p-4 text-sm text-[var(--hiraeth-muted)]">
            No provider runs recorded.
          </div>
        </article>
        <article
          :for={{dom_id, run} <- @runs}
          id={dom_id}
          class={[
            "space-y-4 p-5",
            @selected_run && @selected_run.id == run.id && "bg-[var(--hiraeth-thread-soft)]"
          ]}
        >
          <.link
            id={"admin-quarantine-run-link-#{run.id}"}
            patch={~p"/admin/ingestion/quarantine/runs/#{run.id}"}
            class="qi-action-link break-all font-mono text-sm font-semibold"
          >{run.run_key}</.link>
          <div class="flex flex-wrap items-center gap-2">
            <span class={event_badge_class(run.status)}>{run.status}</span><span class="font-mono text-[11px] text-[var(--hiraeth-label)]">{format_datetime(
              run.started_at || run.inserted_at
            )}</span>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              id={"admin-retry-run-#{run.id}"}
              type="button"
              class="qi-button-secondary"
              phx-click="retry-run"
              phx-value-run-id={run.id}
              disabled={!@can_mutate? || run.status != "failed"}
            >Retry</button>
            <button
              id={"admin-replay-run-#{run.id}"}
              type="button"
              class="qi-button-secondary"
              phx-click="replay-run"
              phx-value-run-id={run.id}
              disabled={!@can_mutate?}
            >Replay</button>
            <button
              id={"admin-cancel-run-#{run.id}"}
              type="button"
              class="qi-button-secondary"
              phx-click="cancel-run"
              phx-value-run-id={run.id}
              disabled={!@can_mutate? || run.status not in ["queued", "running"]}
            >Cancel</button>
            <a
              :if={@can_mutate?}
              id={"admin-export-run-#{run.id}"}
              class="qi-button"
              href={~p"/admin/ingestion/audit/#{run.id}/export"}
            >Export</a>
            <span
              :if={!@can_mutate?}
              id={"admin-export-locked-run-#{run.id}"}
              class="qi-button-secondary opacity-60"
            >Export locked</span>
          </div>
        </article>
      </div>
    </section>
    """
  end

  attr :candidates, :any, required: true
  attr :selected_candidate, :any, default: nil
  attr :review_form, :any, required: true
  attr :can_mutate?, :boolean, default: false

  def candidate_review_panel(assigns) do
    ~H"""
    <section id="admin-candidate-review-panel" class="qi-panel overflow-hidden">
      <div class="border-b qi-divider p-5">
        <p class="qi-label">Candidate diff review</p><p class="mt-2 text-sm text-[var(--hiraeth-muted)]">
          External provider text is rendered as escaped text; destructive diffs require the explicit approval checkbox.
        </p>
      </div>
      <div
        id="admin-quarantine-candidates"
        phx-update="stream"
        class="divide-y divide-[var(--hiraeth-line)]"
      >
        <article id="admin-candidate-empty" class="hidden only:block p-5">
          <div class="qi-empty p-4 text-sm text-[var(--hiraeth-muted)]">
            No candidates require review.
          </div>
        </article>
        <article
          :for={{dom_id, candidate} <- @candidates}
          id={dom_id}
          class={[
            "space-y-4 p-5",
            @selected_candidate && @selected_candidate.id == candidate.id &&
              "bg-[var(--hiraeth-thread-soft)]"
          ]}
        >
          <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div class="min-w-0">
              <.link
                id={"admin-candidate-link-#{candidate.id}"}
                patch={~p"/admin/ingestion/quarantine/candidates/#{candidate.id}"}
                class="qi-action-link break-all font-mono text-sm font-semibold"
              >{candidate.candidate_identity}</.link><p class="mt-2 break-all text-sm text-[var(--hiraeth-muted)]">
                {candidate.source_uri}
              </p>
            </div><div class="flex flex-wrap gap-2">
              <span class={event_badge_class(candidate.diff_classification)}>{candidate.diff_classification}</span><span class={
                event_badge_class(candidate.review_decision)
              }>{candidate.review_decision}</span>
            </div>
          </div>
          <.candidate_diff candidate={candidate} />
          <.review_form :if={@can_mutate?} candidate={candidate} form={@review_form} />
          <p :if={!@can_mutate?} class="text-xs text-[var(--hiraeth-muted)]">
            Candidate decisions require owner or admin role.
          </p>
        </article>
      </div>
    </section>
    """
  end

  attr :candidate, :any, required: true

  defp candidate_diff(assigns) do
    ~H"""
    <dl id={"admin-candidate-diff-#{@candidate.id}"} class="grid gap-3 text-xs md:grid-cols-2">
      <.diff_item label="Normalized title" value={metadata_value(@candidate, "title")} />
      <.diff_item label="Record type" value={@candidate.record_type} />
      <.diff_item
        id={"admin-candidate-validation-#{@candidate.id}"}
        label="Validation"
        value={validation_summary(@candidate.validation_errors)}
      />
      <.diff_item label="Reviewer" value={@candidate.review_actor_email || "not reviewed"} />
    </dl>
    """
  end

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp diff_item(assigns) do
    ~H"""
    <div id={@id} class="border border-[var(--hiraeth-line)] bg-[var(--hiraeth-warm)] p-3">
      <dt class="qi-label">{@label}</dt><dd class="mt-2 break-all text-[var(--hiraeth-ink)]">
        {@value}
      </dd>
    </div>
    """
  end

  attr :candidate, :any, required: true
  attr :form, :any, required: true

  defp review_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id={"admin-review-form-#{@candidate.id}"}
      phx-submit="review-candidate"
      phx-value-candidate-id={@candidate.id}
      class="space-y-3 border-t qi-divider pt-4"
    >
      <.input
        field={@form[:reason]}
        id={"admin-review-reason-#{@candidate.id}"}
        type="textarea"
        label="Reason"
      />
      <label
        :if={RecordCandidate.destructive_diff?(@candidate.diff_classification)}
        id={"admin-approve-destructive-label-#{@candidate.id}"}
        class="flex gap-2 text-xs text-[var(--hiraeth-muted)]"
      ><input
        id={"admin-approve-destructive-#{@candidate.id}"}
        type="checkbox"
        name="review[approve_destructive]"
        value="true"
      /> I explicitly approve this destructive diff.</label>
      <div class="flex flex-wrap gap-2">
        <button
          id={"admin-approve-candidate-#{@candidate.id}"}
          class="qi-button"
          name="review_action"
          value="approve"
        >Approve</button><button
          id={"admin-reject-candidate-#{@candidate.id}"}
          class="qi-button-secondary"
          name="review_action"
          value="reject"
        >Reject</button><button
          id={"admin-ignore-candidate-#{@candidate.id}"}
          class="qi-button-secondary"
          name="review_action"
          value="ignore"
        >Ignore</button>
      </div>
    </.form>
    """
  end

  defp validation_summary(errors) when errors in [nil, []], do: "clear"
  defp validation_summary(errors), do: Enum.join(errors, ", ")

  defp metadata_value(candidate, key),
    do: Map.get(candidate.normalized_metadata || %{}, key, "not recorded")
end
