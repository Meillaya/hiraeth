defmodule HiraethWeb.Admin.AuditExportController do
  use HiraethWeb, :controller

  alias Hiraeth.Accounts
  alias HiraethWeb.Admin.QuarantineControl

  def show(conn, %{"run_id" => run_id}) do
    actor = Accounts.ingestion_actor(conn.assigns.current_admin_user)

    case QuarantineControl.audit_export(run_id, actor) do
      {:ok, payload} ->
        filename = "hiraeth-audit-#{safe_id(run_id)}.json"

        send_download(conn, {:binary, Jason.encode_to_iodata!(payload)},
          content_type: "application/json",
          filename: filename
        )

      {:error, reason} ->
        conn
        |> put_flash(:error, export_error(reason))
        |> redirect(to: ~p"/admin/ingestion/quarantine")
    end
  end

  defp export_error("Only owner or admin operators can use quarantine controls."),
    do: "Only owner or admin operators can export audit data."

  defp export_error(_reason), do: "Audit export was not found."

  defp safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  end
end
