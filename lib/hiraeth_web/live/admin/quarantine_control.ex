defmodule HiraethWeb.Admin.QuarantineControl do
  @moduledoc false

  alias Hiraeth.Ingestion.{IngestionEvent, ProviderRun, RecordCandidate}
  alias Hiraeth.Oban.{ProviderIngestionWorker, SourceSnapshotReplayWorker}
  alias HiraethWeb.Admin.QuarantineStore

  import Ecto.Query

  @catalog_writer %{id: "admin-quarantine-control", catalog_write?: true}

  defdelegate load(params \\ %{}), to: QuarantineStore

  def audit_export(run_id, actor) do
    with :ok <- ensure_admin_actor(actor) do
      QuarantineStore.audit_export(run_id)
    end
  end

  def review_candidate(candidate_id, decision, attrs, actor) do
    with :ok <- ensure_admin_actor(actor),
         {:ok, candidate} <- QuarantineStore.fetch_candidate(candidate_id),
         {:ok, note} <- required_note(attrs["reason"] || attrs[:reason]),
         :ok <- destructive_approval(candidate, decision, attrs),
         {:ok, updated} <- persist_decision(candidate, decision, note, actor),
         :ok <- append_candidate_event(updated, decision, actor, note) do
      {:ok, updated}
    end
  end

  def retry_run(run_id, actor) do
    with :ok <- ensure_admin_actor(actor),
         {:ok, run} <- QuarantineStore.fetch_run(run_id),
         :ok <- ensure_retryable(run),
         {:ok, provider} <- QuarantineStore.fetch_provider(run.provider_source_id),
         {:ok, manifest_path} <- manifest_path(run, provider),
         {:ok, job} <- enqueue_ingestion(run, provider, manifest_path, actor),
         :ok <-
           append_run_event(run, "control:retry", "Retry enqueued by #{actor.email}", %{
             job_id: job.id
           }) do
      {:ok, job}
    end
  end

  def replay_run(run_id, actor) do
    with :ok <- ensure_admin_actor(actor),
         {:ok, run} <- QuarantineStore.fetch_run(run_id),
         {:ok, job} <- enqueue_replay(run, actor),
         :ok <-
           append_run_event(run, "control:replay", "Replay enqueued by #{actor.email}", %{
             job_id: job.id
           }) do
      {:ok, job}
    end
  end

  def cancel_run(run_id, actor) do
    with :ok <- ensure_admin_actor(actor),
         {:ok, run} <- QuarantineStore.fetch_run(run_id),
         :ok <- ensure_cancellable(run),
         cancelled_jobs <- cancel_correlated_jobs(run.id),
         {:ok, cancelled} <- mark_cancelled(run),
         :ok <-
           append_run_event(cancelled, "control:cancel", "Run cancelled by #{actor.email}", %{
             cancelled_jobs: cancelled_jobs
           }) do
      {:ok, cancelled}
    end
  end

  defp ensure_admin_actor(%{catalog_write?: true}), do: :ok

  defp ensure_admin_actor(_),
    do: {:error, "Only owner or admin operators can use quarantine controls."}

  defp required_note(note) when is_binary(note) do
    if String.trim(note) == "",
      do: {:error, "A reason is required."},
      else: {:ok, String.trim(note)}
  end

  defp required_note(_), do: {:error, "A reason is required."}

  defp destructive_approval(candidate, "approve", attrs) do
    if RecordCandidate.destructive_diff?(candidate.diff_classification) and
         attrs["approve_destructive"] != "true" do
      {:error, "Destructive diffs require explicit approval."}
    else
      :ok
    end
  end

  defp destructive_approval(_, _, _), do: :ok

  defp persist_decision(candidate, decision, note, actor) do
    action =
      %{"approve" => :approve_for_apply, "reject" => :reject, "ignore" => :ignore}[decision]

    if action do
      candidate
      |> Ash.Changeset.for_update(action, review_attrs(note, actor))
      |> Ash.update(actor: @catalog_writer)
    else
      {:error, "Unknown candidate review action."}
    end
  end

  defp review_attrs(note, actor) do
    %{
      reviewer_note: note,
      review_actor_id: to_string(actor.id),
      review_actor_email: actor.email,
      reviewed_at: DateTime.utc_now(:second)
    }
  end

  defp ensure_retryable(%ProviderRun{status: "failed"}), do: :ok

  defp ensure_retryable(%ProviderRun{status: status}),
    do: {:error, "Only failed runs can be retried; current status is #{status}."}

  defp ensure_cancellable(%ProviderRun{status: status}) when status in ["queued", "running"],
    do: :ok

  defp ensure_cancellable(%ProviderRun{status: status}),
    do: {:error, "Provider run cannot be cancelled from status #{status}."}

  defp manifest_path(run, provider),
    do:
      ok_present(
        run.provenance["manifest_path"] || provider.manifest_uri,
        "No manifest path is recorded for retry."
      )

  defp ok_present(value, _msg) when is_binary(value) and value != "", do: {:ok, value}
  defp ok_present(_, msg), do: {:error, msg}

  defp enqueue_ingestion(run, provider, manifest_path, actor) do
    ProviderIngestionWorker.new(%{
      provider: run.provenance["manifest_provider"] || provider.stable_source_key,
      manifest_path: manifest_path,
      provider_source_id: provider.id,
      provider_run_id: run.id,
      requested_by: actor.email
    })
    |> Oban.insert()
  end

  defp enqueue_replay(run, actor),
    do:
      SourceSnapshotReplayWorker.new(%{provider_run_id: run.id, requested_by: actor.email})
      |> Oban.insert()

  defp mark_cancelled(run) do
    run
    |> Ash.Changeset.for_update(:cancel, %{finished_at: DateTime.utc_now(:second)})
    |> Ash.update(actor: @catalog_writer)
  end

  defp cancel_correlated_jobs(run_id) do
    Oban.Job
    |> where([job], fragment("?->>? = ?", job.args, "provider_run_id", ^to_string(run_id)))
    |> Hiraeth.Repo.all()
    |> Enum.count(&cancel_job?/1)
  end

  defp cancel_job?(%{state: state}) when state in ["completed", "discarded", "cancelled"],
    do: false

  defp cancel_job?(job), do: Oban.cancel_job(job) == :ok

  defp append_candidate_event(candidate, decision, actor, note) do
    {:ok, run} = QuarantineStore.fetch_run(candidate.provider_run_id)

    append_event(%{
      provider_run_id: candidate.provider_run_id,
      provider_source_id: run.provider_source_id,
      source_snapshot_id: candidate.source_snapshot_id,
      event_kind: "candidate:#{decision}",
      status: "succeeded",
      message: "Candidate #{decision} by #{actor.email}: #{note}",
      payload: %{candidate_id: candidate.id, decision: decision, actor: actor.email},
      occurred_at: DateTime.utc_now(:second)
    })
  end

  defp append_run_event(run, kind, message, payload) do
    append_event(%{
      provider_run_id: run.id,
      provider_source_id: run.provider_source_id,
      event_kind: kind,
      status: "succeeded",
      message: message,
      payload: payload,
      occurred_at: DateTime.utc_now(:second)
    })
  end

  defp append_event(attrs) do
    IngestionEvent
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: @catalog_writer)
    |> case do
      {:ok, _event} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end
end
