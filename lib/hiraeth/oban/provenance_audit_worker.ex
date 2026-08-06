defmodule Hiraeth.Oban.ProvenanceAuditWorker do
  @moduledoc """
  Oban worker for the weekly scheduled provenance audit.

  Runs on the `:audit` queue every Sunday at 04:30 (see the Oban crontab
  in config/config.exs), after the weekly cover refresh. perform/1 calls
  `Hiraeth.ProvenanceAudit.run!/1` directly with the default output dir
  `artifacts/qa/provenance` — the `--output-dir` equivalent is accepted
  as the optional `"output_dir"` job arg.

  AUDIT-ONLY against live data:

    * never seeds (no `--seed` equivalent exists here)
    * never rebuilds or drops the database — the Makefile
      `audit-provenance` target's `mix ecto.drop --force` rebuild is
      deliberately NOT replicated; the scheduled worker audits the live
      catalog and leaves row counts unchanged
    * findings fail the job (run!/1 raises), surfacing them in Oban job
      state instead of silently passing

  Emits one telemetry event: [:hiraeth, :provenance, :scheduled, :audit].
  """

  use Oban.Worker,
    queue: :audit,
    unique: [
      keys: [:audit_key],
      period: 86_400
    ]

  @default_output_dir "artifacts/qa/provenance"
  @scheduled_audit_event [:hiraeth, :provenance, :scheduled, :audit]

  def default_output_dir, do: @default_output_dir

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args = args || %{}
    output_dir = Map.get(args, "output_dir", @default_output_dir)
    started_at = System.monotonic_time(:millisecond)
    audit = Hiraeth.ProvenanceAudit.run!(output_dir: output_dir)
    duration_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      @scheduled_audit_event,
      %{
        source_ledger_rows: audit.source_ledger_rows,
        invalid_public_cover_count: length(audit.invalid_public_covers),
        duration_ms: duration_ms
      },
      %{status: :ok, worker: :provenance_audit_worker}
    )

    {:ok,
     %{
       source_ledger_rows: audit.source_ledger_rows,
       invalid_public_covers: length(audit.invalid_public_covers),
       output_dir: output_dir
     }}
  end
end
