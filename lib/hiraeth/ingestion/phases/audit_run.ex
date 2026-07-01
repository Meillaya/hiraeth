defmodule Hiraeth.Ingestion.Phases.AuditRun do
  @moduledoc "Runs provenance audit as an explicit ingestion phase."

  alias Hiraeth.Ingestion.Phases.RunState
  alias Hiraeth.ProvenanceAudit

  def run(%{provider_run_id: run_id, manifest: manifest} = context) do
    audit = ProvenanceAudit.run!(providers: [manifest.provider])

    RunState.mark_phase(run_id, :audit_run, :succeeded, %{
      source_count: audit.source_records,
      message: "Provenance audit completed for #{manifest.provider}."
    })

    {:ok, Map.put(context, :provenance_audit, audit)}
  rescue
    error ->
      RunState.mark_phase(context.provider_run_id, :audit_run, :failed, %{
        error_count: 1,
        error: %{code: :audit_failed, message: Exception.message(error)}
      })

      {:error, {:audit_failed, Exception.message(error)}}
  end
end
