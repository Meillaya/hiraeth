defmodule Mix.Tasks.Hiraeth.Ingest do
  @moduledoc """
  Ingest a new publisher's book metadata and covers.

  Usage:
      mix hiraeth.ingest --provider <slug> [--manifest <path>]
      mix hiraeth.ingest --provider <slug> [--manifest <path>] [--dry-run] [--json] [--wait]
      mix hiraeth.ingest --cancel <run_id> [--json]
      mix hiraeth.ingest --replay <run_id> [--json]

  The manifest defaults to priv/catalog_sources/provider_manifests/<slug>.json.
  """
  use Mix.Task

  alias Hiraeth.Ingestion.OperatorCLI

  @shortdoc "Ingest a new publisher's book metadata and covers"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case do_run(args) do
      :ok ->
        :ok

      {:error, message} ->
        Mix.shell().error(format_error_message(message))
        exit({:shutdown, 1})
    end
  end

  @doc false
  def do_run(args), do: OperatorCLI.run_args(args)

  defp format_error_message(message) when is_binary(message), do: message
  defp format_error_message(message), do: inspect(message)
end
