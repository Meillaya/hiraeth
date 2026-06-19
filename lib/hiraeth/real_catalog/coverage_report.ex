defmodule Hiraeth.RealCatalog.CoverageReport do
  @moduledoc """
  Builds deterministic coverage reports for the approved real-catalog source corpus.
  """

  alias Hiraeth.RealCatalog.{Dataset, ISBN}

  def build(dir \\ Dataset.default_dir()) do
    with {:ok, datasets} <- Dataset.load_dir(dir),
         {:ok, authority_manifest} <- Dataset.load_source_authority_manifest(dir) do
      {:ok, build(datasets, authority_manifest)}
    end
  end

  def write!(dir \\ Dataset.default_dir(), output_path) do
    {:ok, report} = build(dir)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, Jason.encode!(report, pretty: true) <> "\n")
    report
  end

  defp build(datasets, authority_manifest) do
    providers = Map.get(authority_manifest, "providers", [])

    provider_reports =
      datasets
      |> Enum.sort_by(& &1.provider)
      |> Enum.map(&provider_report(&1, providers))

    %{
      "version" => 1,
      "generated_from" => "checked_in_approved_source_corpus",
      "completeness_boundary" => authority_manifest["completeness_boundary"],
      "totals" => %{
        "providers" => length(provider_reports),
        "attempted_records" => sum(provider_reports, "attempted_records"),
        "approved_source_records" => sum(provider_reports, "approved_source_records"),
        "skipped_source_records" => sum(provider_reports, "skipped_source_records")
      },
      "providers" => provider_reports
    }
  end

  defp provider_report(dataset, providers) do
    provider_policy = Enum.find(providers, &(&1["provider"] == dataset.provider)) || %{}
    records = dataset.records || []

    approved_source_records =
      Enum.count(records, &(get_in(&1, [:curation, :status]) == "approved"))

    status = to_string(provider_policy["status"])

    %{
      "provider" => dataset.provider,
      "dataset_file" => dataset.file,
      "source_status" => provider_policy["status"],
      "source_corpus_boundary" => provider_policy["source_corpus_boundary"],
      "coverage_state" => get_in(provider_policy, ["coverage", "coverage_state"]),
      "expansion_state" => provider_policy["expansion_state"],
      "gap_policy" => get_in(provider_policy, ["coverage", "gap_policy"]),
      "expected_record_count" => get_in(provider_policy, ["coverage", "expected_record_count"]),
      "attempted_records" => length(records),
      "approved_source_records" => approved_source_records,
      "skipped_source_records" => length(records) - approved_source_records,
      "source_blocked" => String.starts_with?(status, "blocked_"),
      "source_expansion_blocked" =>
        String.starts_with?(to_string(provider_policy["expansion_state"]), "blocked_"),
      "gap_counts" => gap_counts(records),
      "checksums" => %{"dataset_sha256" => dataset.file_checksum}
    }
  end

  defp gap_counts(records) do
    %{
      "missing_cover" =>
        Enum.count(
          records,
          &(blank?(cover_source_url(&1)) and
              present?(Map.get(&1, :no_cover_reason) || Map.get(&1, :cover_fallback_reason)))
        ),
      "missing_isbn" => Enum.count(records, &(normalized_isbn(&1) == nil)),
      "missing_purchase_link" => Enum.count(records, &blank?(Map.get(&1, :source_uri))),
      "missing_review_links" => Enum.count(records, &(Map.get(&1, :review_links, []) == [])),
      "structured_missing_fields" =>
        Enum.count(records, &(map_size(Map.get(&1, :missing_fields, %{})) > 0))
    }
  end

  defp cover_source_url(record), do: get_in(record, [:cover, :source_url])

  defp normalized_isbn(record) do
    case ISBN.normalize(get_in(record, [:edition, :isbn_13])) do
      {:ok, isbn} -> isbn
      {:error, _reason} -> nil
    end
  end

  defp sum(provider_reports, key), do: Enum.reduce(provider_reports, 0, &(&1[key] + &2))
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
  defp blank?(value), do: value in [nil, []] or (is_binary(value) and String.trim(value) == "")
end
