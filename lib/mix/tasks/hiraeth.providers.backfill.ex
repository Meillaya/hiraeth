defmodule Mix.Tasks.Hiraeth.Providers.Backfill do
  @moduledoc """
  Backfill `Hiraeth.Ingestion.ProviderSource` rows from checked-in provider inventory.

  Usage:

      mix hiraeth.providers.backfill [--dry-run] [--json]
  """

  use Mix.Task

  alias Hiraeth.Ingestion.ProviderBackfill

  @shortdoc "Backfill ingestion provider sources from deterministic inventory"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, json: :boolean],
        aliases: [n: :dry_run]
      )

    summary =
      if Keyword.get(opts, :dry_run, false) do
        ProviderBackfill.dry_run()
      else
        ProviderBackfill.apply!()
      end

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(ProviderBackfill.json!(summary))
    else
      print_summary(summary)
    end
  end

  defp print_summary(summary) do
    Mix.shell().info("provider_backfill dry_run=#{summary.dry_run}")
    Mix.shell().info("providers=#{summary.total}")

    if Map.has_key?(summary, :created) do
      Mix.shell().info("created=#{summary.created} updated=#{summary.updated}")
      Mix.shell().info("stale_disabled=#{summary.stale_disabled}")

      if summary.stale_provider_keys != [] do
        Mix.shell().info("stale_provider_keys=#{Enum.join(summary.stale_provider_keys, ",")}")
      end
    end

    manual_count = Enum.count(summary.providers, &(&1["ingestion_mode"] == "manual"))
    enabled_count = Enum.count(summary.providers, & &1["enabled?"])

    Mix.shell().info("enabled=#{enabled_count} manual=#{manual_count}")
  end
end
