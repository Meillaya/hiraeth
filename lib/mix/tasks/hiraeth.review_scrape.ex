defmodule Mix.Tasks.Hiraeth.ReviewScrape do
  @moduledoc """
  Compare a staged dataset against the current checked-in dataset for a provider.

  Usage:
      mix hiraeth.review_scrape --provider <slug>

  Loads:
    - priv/catalog_sources/staged/<provider>.json
    - priv/catalog_sources/real_publishers/<provider>.json

  Builds an identity key for each record from `edition.isbn_13` when present,
  otherwise from `source_product_id`. Prints total counts plus new, missing, and
  changed record details, then exits 0. Only missing files cause a non-zero exit.
  """
  use Mix.Task

  alias Hiraeth.RealCatalog.Dataset

  @shortdoc "Compare staged dataset against current dataset for a provider"

  @compare_fields [
    {:work_title, [:work, :title]},
    {:contributors, [:contributors]},
    {:publisher, [:publisher]},
    {:edition_format, [:edition, :format]},
    {:edition_published_on, [:edition, :published_on]},
    {:description, [:description]},
    {:cover_source_url, [:cover, :source_url]}
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case do_run(args) do
      :ok ->
        :ok

      {:error, message} ->
        Mix.shell().error(message)
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
      {:error, "Usage: mix hiraeth.review_scrape --provider <slug>"}
    else
      compare_datasets(provider)
    end
  end

  defp compare_datasets(provider) do
    staged_path = staged_dataset_path(provider)
    current_path = current_dataset_path(provider)

    with {:ok, staged} <- load_dataset(staged_path, "staged"),
         {:ok, current} <- load_dataset(current_path, "current") do
      staged_map = build_identity_map(staged.records)
      current_map = build_identity_map(current.records)

      staged_keys = MapSet.new(Map.keys(staged_map))
      current_keys = MapSet.new(Map.keys(current_map))

      new_keys =
        MapSet.difference(staged_keys, current_keys) |> MapSet.to_list() |> Enum.sort()

      missing_keys =
        MapSet.difference(current_keys, staged_keys) |> MapSet.to_list() |> Enum.sort()

      common_keys =
        MapSet.intersection(staged_keys, current_keys) |> MapSet.to_list() |> Enum.sort()

      changed =
        Enum.reduce(common_keys, [], fn key, acc ->
          staged_record = Map.fetch!(staged_map, key)
          current_record = Map.fetch!(current_map, key)

          case record_changes(staged_record, current_record) do
            [] -> acc
            changes -> [{key, changes} | acc]
          end
        end)
        |> Enum.reverse()

      print_report(
        provider: provider,
        staged_count: map_size(staged_map),
        current_count: map_size(current_map),
        new_keys: new_keys,
        missing_keys: missing_keys,
        changed: changed
      )

      :ok
    end
  end

  defp load_dataset(path, label) do
    case Dataset.load_file(path) do
      {:ok, dataset} ->
        {:ok, dataset}

      {:error, {:enoent, ^path}} ->
        {:error, "#{label} dataset not found: #{path}"}

      {:error, {reason, ^path}} when is_atom(reason) ->
        {:error, "failed to load #{label} dataset #{path}: #{reason}"}

      {:error, reason} ->
        {:error, "failed to load #{label} dataset #{path}: #{inspect(reason)}"}
    end
  end

  defp build_identity_map(records) do
    records
    |> Enum.reduce(%{}, fn record, acc ->
      Map.put(acc, identity_key(record), record)
    end)
  end

  defp identity_key(record) do
    case get_in(record, [:edition, :isbn_13]) do
      nil -> record[:source_product_id]
      "" -> record[:source_product_id]
      isbn -> isbn
    end
  end

  defp record_changes(staged, current) do
    Enum.flat_map(@compare_fields, fn {label, path} ->
      staged_value = get_in(staged, path)
      current_value = get_in(current, path)

      if staged_value == current_value do
        []
      else
        [{label, current_value, staged_value}]
      end
    end)
  end

  defp print_report(opts) do
    provider = Keyword.fetch!(opts, :provider)
    staged_count = Keyword.fetch!(opts, :staged_count)
    current_count = Keyword.fetch!(opts, :current_count)
    new_keys = Keyword.fetch!(opts, :new_keys)
    missing_keys = Keyword.fetch!(opts, :missing_keys)
    changed = Keyword.fetch!(opts, :changed)

    new_count = length(new_keys)
    missing_count = length(missing_keys)
    changed_count = length(changed)

    Mix.shell().info("Review scrape diff for provider: #{provider}")

    Mix.shell().info(
      "staged=#{staged_count} current=#{current_count} new=#{new_count} missing=#{missing_count} changed=#{changed_count}"
    )

    if new_count == 0 and missing_count == 0 and changed_count == 0 do
      Mix.shell().info("No differences found between staged and current datasets.")
    else
      if new_keys != [] do
        Mix.shell().info("")
        Mix.shell().info("New records (+#{new_count}):")
        Enum.each(new_keys, &Mix.shell().info("  + #{&1}"))
      end

      if missing_keys != [] do
        Mix.shell().info("")
        Mix.shell().info("Missing records (-#{missing_count}):")
        Enum.each(missing_keys, &Mix.shell().info("  - #{&1}"))
      end

      if changed != [] do
        Mix.shell().info("")
        Mix.shell().info("Changed records (~#{changed_count}):")

        Enum.each(changed, fn {key, changes} ->
          Mix.shell().info("  ~ #{key}")

          Enum.each(changes, fn {field, current_value, staged_value} ->
            Mix.shell().info(
              "    #{field}: #{format_value(current_value)} -> #{format_value(staged_value)}"
            )
          end)
        end)
      end
    end
  end

  defp format_value(value), do: inspect(value)

  defp staged_dataset_path(provider) do
    base_dir = Application.app_dir(:hiraeth, "priv/catalog_sources/staged")
    Path.join(base_dir, "#{provider}.json")
  end

  defp current_dataset_path(provider) do
    base_dir = Application.app_dir(:hiraeth, "priv/catalog_sources/real_publishers")
    Path.join(base_dir, "#{provider}.json")
  end
end
