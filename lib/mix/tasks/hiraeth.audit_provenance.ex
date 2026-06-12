defmodule Mix.Tasks.Hiraeth.AuditProvenance do
  @moduledoc "Exports Hiraeth provenance audit CSV/JSON evidence."
  use Mix.Task

  @shortdoc "Exports provenance audit evidence"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [output_dir: :string, seed: :boolean, no_fail: :boolean],
        aliases: [o: :output_dir]
      )

    if Keyword.get(opts, :seed, false), do: Hiraeth.DemoFixtures.seed!()

    output_dir = Keyword.get(opts, :output_dir, "artifacts/qa/provenance")
    fail_on_error? = not Keyword.get(opts, :no_fail, false)
    audit = Hiraeth.ProvenanceAudit.run!(output_dir: output_dir, fail_on_error?: fail_on_error?)

    Mix.shell().info("provenance audit exported to #{output_dir}")
    Mix.shell().info("source_ledger_rows=#{audit.source_ledger_rows}")
    Mix.shell().info("invalid_public_covers=#{length(audit.invalid_public_covers)}")
  end
end
