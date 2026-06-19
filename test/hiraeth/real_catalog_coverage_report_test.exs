defmodule Hiraeth.RealCatalogCoverageReportTest do
  use ExUnit.Case, async: true

  alias Hiraeth.RealCatalog.CoverageReport

  @dataset_dir Path.expand("../../priv/catalog_sources/real_publishers", __DIR__)
  @coverage_report Path.join(@dataset_dir, "source_coverage_report.json")

  test "checked-in coverage report matches approved source corpus" do
    assert {:ok, built} = CoverageReport.build(@dataset_dir)

    checked_in =
      @coverage_report
      |> File.read!()
      |> Jason.decode!()

    assert checked_in == built
    assert built["completeness_boundary"] == "approved_source_corpus"

    assert built["totals"] == %{
             "providers" => 18,
             "attempted_records" => 7406,
             "approved_source_records" => 7406,
             "skipped_source_records" => 0
           }

    for provider <- built["providers"] do
      assert provider["attempted_records"] == provider["expected_record_count"]
      assert provider["approved_source_records"] == provider["attempted_records"]
      assert provider["skipped_source_records"] == 0
      assert provider["gap_policy"] == "import_with_gaps"
      assert is_binary(provider["checksums"]["dataset_sha256"])
      assert byte_size(provider["checksums"]["dataset_sha256"]) == 64
    end
  end

  test "coverage report preserves authorized full-catalog gaps without fabricating records" do
    assert {:ok, report} = CoverageReport.build(@dataset_dir)

    new_directions = provider!(report, "new_directions_official_site")
    refute new_directions["source_blocked"]
    refute new_directions["source_expansion_blocked"]
    assert new_directions["source_status"] == "approved_official_html_source_available"
    assert new_directions["gap_counts"]["missing_cover"] == 0
    assert new_directions["approved_source_records"] == 2389

    transit = provider!(report, "transit_books_official_site")
    refute transit["source_blocked"]
    assert transit["gap_counts"]["missing_cover"] == 0
    assert transit["gap_counts"]["missing_review_links"] == 66

    historical_materialism = provider!(report, "historical_materialism_official_site")
    assert historical_materialism["approved_source_records"] == 384
    assert historical_materialism["gap_counts"]["missing_isbn"] == 384

    semiotexte = provider!(report, "semiotexte_official_site")
    assert semiotexte["approved_source_records"] == 265
    assert semiotexte["gap_counts"]["missing_cover"] == 0

    deep_vellum = provider!(report, "deep_vellum_official_store")
    dalkey_archive = provider!(report, "dalkey_archive_official_store")

    assert deep_vellum["gap_counts"]["missing_cover"] == 1
    assert dalkey_archive["gap_counts"]["missing_cover"] == 3
    assert deep_vellum["gap_counts"]["missing_isbn"] == 0

    nyrb = provider!(report, "nyrb_official_store")
    assert nyrb["approved_source_records"] == 859

    seven_stories = provider!(report, "seven_stories_press_official_site")
    assert seven_stories["approved_source_records"] == 703
    assert seven_stories["gap_counts"]["missing_isbn"] == 703

    pushkin = provider!(report, "pushkin_press_official_site")
    assert pushkin["approved_source_records"] == 74

    fitzcarraldo = provider!(report, "fitzcarraldo_editions_official_site")
    assert fitzcarraldo["approved_source_records"] == 392
    assert fitzcarraldo["gap_counts"]["missing_cover"] == 0
  end

  test "repeat coverage report writes are stable" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-coverage-report-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    first = Path.join(tmp, "first.json")
    second = Path.join(tmp, "second.json")

    CoverageReport.write!(@dataset_dir, first)
    CoverageReport.write!(@dataset_dir, second)

    assert File.read!(first) == File.read!(second)
  end

  defp provider!(report, provider) do
    Enum.find(report["providers"], &(&1["provider"] == provider)) ||
      flunk("missing provider #{provider}")
  end
end
