defmodule Mix.Tasks.Hiraeth.RealCatalog.CoverageReport do
  @moduledoc "Writes the deterministic real-catalog coverage report."
  use Mix.Task

  alias Hiraeth.RealCatalog.{CoverageReport, Dataset}

  @shortdoc "Writes real catalog approved-source coverage report"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [dataset_dir: :string, output: :string],
        aliases: [o: :output]
      )

    dataset_dir = Keyword.get(opts, :dataset_dir, Dataset.default_dir())

    output =
      Keyword.get(opts, :output, Path.join(dataset_dir, "source_coverage_report.json"))

    report = CoverageReport.write!(dataset_dir, output)
    Mix.shell().info("wrote #{output}")

    Mix.shell().info(
      "providers=#{report["totals"]["providers"]} approved_source_records=#{report["totals"]["approved_source_records"]}"
    )
  end
end
