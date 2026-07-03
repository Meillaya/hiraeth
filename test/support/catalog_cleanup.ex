defmodule Hiraeth.CatalogCleanup do
  @moduledoc false

  alias Ecto.Adapters.SQL.Sandbox
  alias Hiraeth.RealCatalog.{Dataset, Importer, SourceArtifacts}
  alias Hiraeth.Repo

  @tables ~w(
    source_ledger_entries
    curation_overrides
    source_records
    import_runs
    cover_assignments
    cover_assets
    identifiers
    contributions
    series_memberships
    editions
    works
    series
    imprints
    contributors
    publishers
    oban_jobs
  )

  @ingestion_control_plane_tables ~w(
    ingestion_events
    record_candidates
    source_snapshots
    provider_runs
    provider_sources
    oban_jobs
  )

  def reset_committed_catalog! do
    reset_committed_tables!(@tables)
  end

  def reset_committed_catalog_with_fixtures! do
    Sandbox.unboxed_run(Repo, fn ->
      truncate_tables!(@tables)
      seed_committed_catalog_fixtures!()
    end)

    clear_public_catalog_cache!()
  end

  def ensure_committed_catalog_fixtures! do
    :global.trans(
      {__MODULE__, :committed_catalog_fixtures},
      fn ->
        Sandbox.unboxed_run(Repo, fn ->
          unless committed_catalog_seeded?() do
            truncate_tables!(@tables)
            seed_committed_catalog_fixtures!()
          end
        end)
      end,
      [node()],
      :infinity
    )

    clear_public_catalog_cache!()
  end

  def committed_catalog_fixtures_ready? do
    Sandbox.unboxed_run(Repo, &committed_catalog_seeded?/0)
  end

  def reset_committed_ingestion_control_plane! do
    reset_committed_tables!(@ingestion_control_plane_tables)
  end

  def clear_catalog!, do: :ok

  defp clear_public_catalog_cache! do
    if Code.ensure_loaded?(HiraethWeb.PublicCatalog) do
      HiraethWeb.PublicCatalog.clear_cache()
    end
  end

  defp committed_catalog_seeded? do
    case expected_committed_catalog_shape() do
      {:ok, expected_shape} -> committed_catalog_shape() == expected_shape
      {:error, _reason} -> false
    end
  end

  defp seed_committed_catalog_fixtures! do
    fixture_dir = committed_catalog_fixture_dir()

    if Path.expand(fixture_dir) == Path.expand(Dataset.default_dir()) do
      {:ok, _summary} = Hiraeth.RealCatalogFixtures.seed!()
    else
      {:ok, _summary} = Importer.seed!(fixture_dir)
    end
  end

  defp committed_catalog_fixture_dir do
    Application.get_env(:hiraeth, :committed_catalog_fixture_dir, Dataset.default_dir())
  end

  defp expected_committed_catalog_shape do
    with {:ok, manifest} <- SourceArtifacts.build_manifest(committed_catalog_fixture_dir()) do
      shape =
        manifest["artifacts"]
        |> Enum.map(fn artifact ->
          identities =
            artifact["source_record_entries"]
            |> Enum.map(&committed_source_identity/1)
            |> Enum.sort()

          {
            artifact["provider"],
            artifact["dataset_sha256"],
            artifact["record_count"],
            checksum_identities(identities)
          }
        end)
        |> Enum.sort()

      {:ok, shape}
    end
  end

  defp committed_source_identity(%{"identity" => "isbn:" <> isbn}), do: isbn
  defp committed_source_identity(%{"identity" => identity}), do: identity

  defp committed_catalog_shape do
    Repo.query!(
      """
      select
        provider,
        file_checksum,
        count(*)::bigint,
        count(edition_id)::bigint,
        array_agg(source_identity order by source_identity)
      from source_records
      where source_type = 'publisher_dataset'
      group by provider, file_checksum
      order by provider, file_checksum
      """,
      []
    ).rows
    |> Enum.map(fn [provider, file_checksum, count, linked_editions, identities] ->
      identities = identities || []

      {
        provider,
        file_checksum,
        count,
        linked_editions,
        checksum_identities(identities)
      }
    end)
    |> Enum.sort()
    |> Enum.map(fn {provider, file_checksum, count, linked_editions, identities_checksum} ->
      if linked_editions == count do
        {provider, file_checksum, count, identities_checksum}
      else
        {provider, file_checksum, {:incomplete_links, count}, identities_checksum}
      end
    end)
  end

  defp checksum_identities(identities) do
    identities
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp reset_committed_tables!(tables) do
    Sandbox.unboxed_run(Repo, fn -> truncate_tables!(tables) end)
  end

  defp truncate_tables!(tables) do
    Repo.query!("TRUNCATE TABLE #{table_list(tables)} RESTART IDENTITY CASCADE", [],
      timeout: :infinity
    )
  end

  defp table_list(tables) do
    Enum.map_join(tables, ", ", &~s("#{&1}"))
  end
end
