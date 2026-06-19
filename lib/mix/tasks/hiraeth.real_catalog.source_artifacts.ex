defmodule Mix.Tasks.Hiraeth.RealCatalog.SourceArtifacts do
  @moduledoc "Writes the deterministic real-catalog source artifact manifest."
  use Mix.Task

  @shortdoc "Writes source artifact manifest for checked-in real catalog fixtures"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [dataset_dir: :string, output: :string],
        aliases: [o: :output]
      )

    dataset_dir = Keyword.get(opts, :dataset_dir, Hiraeth.RealCatalog.Dataset.default_dir())

    output =
      Keyword.get(
        opts,
        :output,
        Path.join(dataset_dir, "source_artifacts_manifest.json")
      )

    manifest = Hiraeth.RealCatalog.SourceArtifacts.write_manifest!(dataset_dir, output)
    Mix.shell().info("wrote #{output}")

    Mix.shell().info(
      "artifacts=#{length(manifest["artifacts"])} records=#{manifest["total_records"]}"
    )
  end
end
