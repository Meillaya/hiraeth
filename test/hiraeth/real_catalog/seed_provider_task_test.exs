defmodule Hiraeth.RealCatalog.SeedProviderTaskTest do
  use Hiraeth.DataCase, async: false

  @moduletag :reset_committed_catalog

  alias Hiraeth.Catalog.{Edition, Publisher}
  alias Hiraeth.CatalogCleanup
  alias Hiraeth.Imports.ImportRun
  alias Mix.Tasks.Hiraeth.RealCatalog.SeedProvider

  require Ash.Query

  @fixture_path Path.join([
                  File.cwd!(),
                  "test/fixtures/provider_seed/valid_provider.json"
                ])

  @test_provider "real_catalog_seed_provider_task_test"

  setup do
    clear_catalog!()
    dataset_dir = make_tmp_dataset_dir!()

    on_exit(fn ->
      cleanup_dataset!(@test_provider)
      File.rm_rf!(dataset_dir)
      Application.delete_env(:hiraeth, :seed_provider_dataset_dir)
    end)

    :ok
  end

  describe "happy path" do
    @tag timeout: 60_000
    test "seeds a single provider dataset from priv/catalog_sources/real_publishers" do
      dataset_path = prepare_dataset_file!(@test_provider, @fixture_path)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = SeedProvider.run(["--provider", @test_provider])
        end)

      assert File.exists?(dataset_path)

      assert output =~ "Seeded provider: #{@test_provider}"
      assert output =~ "records_imported=3"

      editions = Ash.read!(Edition, authorize?: false)
      assert length(editions) == 3

      publishers = Ash.read!(Publisher, authorize?: false)
      assert Enum.any?(publishers, &(&1.name == "Test Provider Press"))

      import_runs =
        ImportRun
        |> Ash.Query.filter(provider: @test_provider, status: "applied")
        |> Ash.read!(authorize?: false)

      assert length(import_runs) == 1
      assert hd(import_runs).row_limit == 3
    end
  end

  describe "argument validation" do
    test "missing --provider exits 1 with usage" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert catch_exit(SeedProvider.run([])) == {:shutdown, 1}
        end)

      assert output =~ "Usage: mix hiraeth.real_catalog.seed_provider"
    end

    test "missing dataset file exits 1 with message" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert catch_exit(SeedProvider.run(["--provider", "definitely_not_a_real_provider"])) ==
                   {:shutdown, 1}
        end)

      assert output =~ "Dataset file not found"
    end
  end

  describe "idempotency" do
    @tag timeout: 60_000
    test "re-running the same provider does not duplicate editions" do
      prepare_dataset_file!(@test_provider, @fixture_path)

      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = SeedProvider.run(["--provider", @test_provider])
      end)

      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = SeedProvider.run(["--provider", @test_provider])
      end)

      # Each Ash resource is upserted by identity; only the import run count
      # should grow, not the catalog rows.
      editions = Ash.read!(Edition, authorize?: false)
      assert length(editions) == 3

      import_runs =
        ImportRun
        |> Ash.Query.filter(provider: @test_provider, status: "applied")
        |> Ash.read!(authorize?: false)

      assert length(import_runs) == 2
    end
  end

  # --- helpers ------------------------------------------------------------

  defp clear_catalog!, do: CatalogCleanup.clear_catalog!()

  # Transient datasets live in a unique per-run tmp dir, never in the governed
  # priv/catalog_sources/real_publishers/ corpus dir (priv/AGENTS.md
  # anti-pattern). The task resolves the dir through the
  # :seed_provider_dataset_dir app-env seam, set here and restored on exit.
  defp make_tmp_dataset_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hiraeth_seed_provider_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    Application.put_env(:hiraeth, :seed_provider_dataset_dir, dir)
    dir
  end

  defp prepare_dataset_file!(provider, source_path) do
    target_path = canonical_dataset_path(provider)
    File.mkdir_p!(Path.dirname(target_path))
    File.cp!(source_path, target_path)
    target_path
  end

  defp canonical_dataset_path(provider) do
    Path.join(dataset_dir(), "#{provider}.json")
  end

  defp dataset_dir, do: Application.get_env(:hiraeth, :seed_provider_dataset_dir)

  defp cleanup_dataset!(provider) do
    path = canonical_dataset_path(provider)
    if File.exists?(path), do: File.rm!(path)
  end
end
