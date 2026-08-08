defmodule Mix.Tasks.Hiraeth.RealCatalog.SeedProvider do
  @moduledoc """
  Seed a single real-publisher dataset from `priv/catalog_sources/real_publishers/`.

  Usage:
      mix hiraeth.real_catalog.seed_provider --provider <slug>

  The mix task is the per-provider recovery path: when the whole-corpus
  `mix run priv/repo/seeds.exs` aborts midway through a single provider, the
  remaining providers can be resumed one at a time without re-importing the
  already-committed ones.

  Idempotent: re-running the same provider refreshes source records whose
  checksum no longer matches and leaves existing rows untouched. Each
  provider runs in its own `Ash.transact` so any error is scoped to that
  provider only.

  Exit codes:
    - 0 on success
    - 1 on missing arguments, missing dataset file, validation failure, or import failure
  """

  use Mix.Task

  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.RealCatalog.{Dataset, Importer, SourcePolicy, Validator}

  @shortdoc "Seed a single real-publisher dataset via Importer.seed_provider!"

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
  def do_run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          provider: :string
        ]
      )

    provider = Keyword.get(opts, :provider)

    if is_nil(provider) or String.trim(provider) == "" do
      {:error, "Usage: mix hiraeth.real_catalog.seed_provider --provider <slug>"}
    else
      seed_provider(provider)
    end
  end

  defp seed_provider(provider) do
    dataset_path = canonical_dataset_path(provider)

    with true <- File.exists?(dataset_path),
         {:ok, dataset} <- Dataset.load_file(dataset_path),
         :ok <- validate_if_manifested(dataset),
         import_run <- create_import_run!(dataset, provider),
         {:ok, _summary} <- Importer.seed_provider!(dataset, import_run, prune_stale?: true) do
      print_summary(provider, dataset)
      :ok
    else
      false -> {:error, "Dataset file not found: #{dataset_path}"}
      {:error, findings} when is_list(findings) -> {:error, format_findings(provider, findings)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Validation runs only when a provider manifest is checked in. Mirrors the
  # apply_scrape lane so side-channel callers (the recovery path used when
  # the whole-corpus seed aborted) do not require a manifest to exist.
  defp validate_if_manifested(dataset) do
    if File.exists?(provider_manifest_path(dataset.provider)) do
      SourcePolicy.load_provider_manifest(provider_manifest_path(dataset.provider))

      case Validator.validate_datasets([dataset]) do
        {:ok, _summary} -> :ok
        {:error, findings} -> {:error, findings}
      end
    else
      :ok
    end
  end

  defp provider_manifest_path(provider) do
    Path.join(
      Application.app_dir(:hiraeth, "priv/catalog_sources/provider_manifests"),
      "#{provider}.json"
    )
  end

  defp create_import_run!(dataset, provider) do
    ImportRun
    |> Ash.Changeset.for_create(:create, %{
      provider: provider,
      status: "applied",
      row_limit: length(dataset.records || [])
    })
    |> Ash.create!(authorize?: false)
  end

  defp print_summary(provider, dataset) do
    Mix.shell().info("Seeded provider: #{provider}")
    Mix.shell().info("records_imported=#{length(dataset.records || [])}")
  end

  defp format_findings(provider, findings) do
    samples = findings |> Enum.take(3) |> Enum.map_join("; ", & &1.reason)

    "Validator blocked seed for provider=#{provider}: #{length(findings)} findings (first: #{samples})"
  end

  # Dataset dir resolves at runtime via Application.app_dir (release-safe),
  # mirroring Dataset.default_dir/0. The app-env override exists as the test
  # seam: the task test must not write transient datasets into the governed
  # priv/catalog_sources/real_publishers/ dir (priv/AGENTS.md anti-pattern).
  defp dataset_dir do
    Application.get_env(:hiraeth, :seed_provider_dataset_dir, Dataset.default_dir())
  end

  defp canonical_dataset_path(provider) do
    Path.join(dataset_dir(), "#{provider}.json")
  end

  defp format_error_message(message) when is_binary(message), do: message
  defp format_error_message(message), do: inspect(message)
end
