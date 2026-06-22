defmodule Mix.Tasks.Hiraeth.ApplyScrape do
  @moduledoc """
  Apply a staged provider dataset to the real_publishers corpus and import it.

  Usage:
      mix hiraeth.apply_scrape --provider <slug>

  The task:
    1. Verifies `priv/catalog_sources/staged/<provider>.json` exists.
    2. Copies it to `priv/catalog_sources/real_publishers/<provider>.json`,
       overwriting any existing fixture.
    3. Removes the staged file only after the copy succeeds.
    4. Loads the canonical fixture with `Hiraeth.RealCatalog.Dataset.load_file/1`.
    5. Creates an `ImportRun` with status `"applied"`.
    6. Imports via `Hiraeth.RealCatalog.Importer.seed_provider!/2`, which prunes
       stale source records whose checksum no longer matches.

  Exit codes:
    - 0 on success
    - 1 on missing arguments, missing staged file, or import failure
  """

  use Mix.Task

  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.RealCatalog.{Dataset, Importer, SourcePolicy, Validator}
  alias Hiraeth.Sources.SourceRecord

  require Ash.Query

  @shortdoc "Apply a staged scrape dataset and import it into the catalog"

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
      {:error, "Usage: mix hiraeth.apply_scrape --provider <slug>"}
    else
      apply_provider(provider)
    end
  end

  defp apply_provider(provider) do
    staged_path = staged_dataset_path(provider)
    canonical_path = canonical_dataset_path(provider)

    unless File.exists?(staged_path) do
      {:error, "Staged dataset not found: #{staged_path}"}
    else
      File.mkdir_p!(Path.dirname(canonical_path))

      with {:ok, staged_dataset} <- Dataset.load_file(staged_path),
           :ok <- validate_staged_dataset(staged_dataset) do
        # Copy then remove so the staged file survives validation or copy failure.
        File.cp!(staged_path, canonical_path)
        File.rm!(staged_path)

        with {:ok, dataset} <- Dataset.load_file(canonical_path),
             import_run <- create_import_run!(dataset),
             stale_before <- count_provider_source_records(provider),
             {:ok, _summary} <- Importer.seed_provider!(dataset, import_run) do
          source_records_after = count_provider_source_records(provider)
          stale_pruned = stale_before

          print_summary(provider, dataset, source_records_after, stale_pruned)
          :ok
        else
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp validate_staged_dataset(dataset) do
    if validation_required?(dataset) do
      register_manifest_provider(dataset.provider)

      case Validator.validate_datasets([dataset]) do
        {:ok, _summary} -> :ok
        {:error, findings} -> {:error, findings}
      end
    else
      :ok
    end
  end

  defp validation_required?(dataset) do
    File.exists?(provider_manifest_path(dataset.provider))
  end

  defp register_manifest_provider(provider) do
    path = provider_manifest_path(provider)

    if File.exists?(path) do
      SourcePolicy.load_provider_manifest(path)
    end

    :ok
  end

  defp create_import_run!(dataset) do
    ImportRun
    |> Ash.Changeset.for_create(:create, %{
      provider: dataset.provider,
      status: "applied",
      row_limit: length(dataset.records || [])
    })
    |> Ash.create!(authorize?: false)
  end

  defp count_provider_source_records(provider) do
    SourceRecord
    |> Ash.Query.filter(provider: provider, source_type: "publisher_dataset")
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp print_summary(provider, dataset, source_records_after, stale_pruned) do
    Mix.shell().info("Applied staged dataset for provider: #{provider}")
    Mix.shell().info("records_imported=#{length(dataset.records || [])}")
    Mix.shell().info("source_records_created=#{source_records_after}")
    Mix.shell().info("stale_records_pruned=#{stale_pruned}")
    Mix.shell().info("canonical_file=#{dataset.file_path}")
  end

  defp provider_manifest_path(provider) do
    base_dir = Application.app_dir(:hiraeth, "priv/catalog_sources/provider_manifests")
    Path.join(base_dir, "#{provider}.json")
  end

  defp staged_dataset_path(provider) do
    Application.app_dir(:hiraeth, "priv/catalog_sources/staged/#{provider}.json")
  end

  defp canonical_dataset_path(provider) do
    Application.app_dir(:hiraeth, "priv/catalog_sources/real_publishers/#{provider}.json")
  end

  defp format_error_message(message) when is_binary(message), do: message
  defp format_error_message(message), do: inspect(message)
end
