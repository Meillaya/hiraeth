defmodule Hiraeth.RealCatalog.SourceArtifacts do
  @moduledoc """
  Builds deterministic source-artifact manifests from checked-in real-catalog fixtures.
  """

  alias Hiraeth.RealCatalog.{Dataset, ISBN}

  def build_manifest(dir \\ Dataset.default_dir()) do
    with {:ok, datasets} <- Dataset.load_dir(dir),
         {:ok, authority_manifest} <- Dataset.load_source_authority_manifest(dir) do
      {:ok, build_manifest(datasets, authority_manifest)}
    end
  end

  def write_manifest!(dir \\ Dataset.default_dir(), output_path) do
    {:ok, manifest} = build_manifest(dir)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, Jason.encode!(manifest, pretty: true) <> "\n")
    manifest
  end

  defp build_manifest(datasets, authority_manifest) do
    providers = Map.get(authority_manifest, "providers", [])

    artifacts =
      datasets
      |> Enum.sort_by(& &1.provider)
      |> Enum.map(&artifact_entry(&1, providers))

    %{
      "version" => 1,
      "generated_from" => "checked_in_real_publisher_fixtures",
      "source_authority_manifest" => Dataset.source_authority_manifest_file(),
      "completeness_boundary" => authority_manifest["completeness_boundary"],
      "total_records" => Enum.reduce(artifacts, 0, &(&1["record_count"] + &2)),
      "artifacts" => artifacts
    }
  end

  defp artifact_entry(dataset, providers) do
    provider_policy = Enum.find(providers, &(&1["provider"] == dataset.provider)) || %{}
    records = dataset.records || []

    %{
      "provider" => dataset.provider,
      "dataset_file" => dataset.file,
      "dataset_sha256" => dataset.file_checksum,
      "retrieved_at" => dataset.retrieved_at,
      "record_count" => length(records),
      "approved_count" => Enum.count(records, &(get_in(&1, [:curation, :status]) == "approved")),
      "expected_record_count" => get_in(provider_policy, ["coverage", "expected_record_count"]),
      "allowed_source_urls" => Map.get(provider_policy, "allowed_source_urls", []),
      "allowed_source_types" => Map.get(provider_policy, "allowed_source_types", []),
      "max_response_bytes" => get_in(provider_policy, ["max_bytes", "response"]),
      "source_record_entries" => Enum.map(records, &source_record_entry(dataset.provider, &1))
    }
  end

  defp source_record_entry(provider, record) do
    isbn = normalized_isbn(record)

    %{
      "source_product_id" => record.source_product_id,
      "source_uri" => record.source_uri,
      "identity" => source_identity(provider, record, isbn),
      "isbn_13" => isbn,
      "missing_fields" => stringify_map_keys(Map.get(record, :missing_fields, %{}))
    }
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_map_keys(_value), do: %{}

  defp source_identity(provider, record, nil),
    do: "source:#{provider}:#{record.source_product_id}"

  defp source_identity(_provider, _record, isbn), do: "isbn:#{isbn}"

  defp normalized_isbn(record) do
    case ISBN.normalize(get_in(record, [:edition, :isbn_13])) do
      {:ok, isbn} -> isbn
      {:error, _reason} -> nil
    end
  end
end
