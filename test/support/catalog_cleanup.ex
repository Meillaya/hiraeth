defmodule Hiraeth.CatalogCleanup do
  @moduledoc false

  alias Ecto.Adapters.SQL.Sandbox
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
      Hiraeth.RealCatalogFixtures.seed!()
    end)
  end

  def ensure_committed_catalog_fixtures! do
    :global.trans(
      {__MODULE__, :committed_catalog_fixtures},
      fn ->
        Sandbox.unboxed_run(Repo, fn ->
          unless committed_catalog_seeded?() do
            truncate_tables!(@tables)
            Hiraeth.RealCatalogFixtures.seed!()
          end
        end)
      end,
      [node()],
      :infinity
    )
  end

  def reset_committed_ingestion_control_plane! do
    reset_committed_tables!(@ingestion_control_plane_tables)
  end

  def clear_catalog!, do: :ok

  defp committed_catalog_seeded? do
    Repo.query!(
      """
      select exists(
        select 1
        from source_records sr
        join editions e on e.id = sr.edition_id
        where sr.provider = 'deep_vellum_official_store'
          and e.slug = 'deep-vellum-immigrant-paperback-9781646054541'
      )
      """,
      []
    ).rows == [[true]]
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
