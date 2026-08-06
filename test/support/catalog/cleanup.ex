defmodule Hiraeth.CatalogCleanup do
  @moduledoc false

  alias Ecto.Adapters.SQL.Sandbox
  alias Hiraeth.RealCatalog.{Dataset, Importer, SourceArtifacts}
  alias Hiraeth.Repo

  # Child-first order (FKs are RESTRICT by default): every table precedes any
  # table it references. Resets delete in this exact order, so concurrent
  # full-table DELETEs lock rows in the same order and can never deadlock.
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

  @full_corpus_seed_lock {__MODULE__, :full_corpus_seed}

  def reset_committed_catalog! do
    with_committed_catalog_fixture_lock(fn ->
      reset_committed_tables!(@tables)
      :ok
    end)
  end

  # Sandbox-scoped variant: runs inside the caller's sandbox transaction, so
  # it only clears the test's own view and rolls back with it. The committed
  # corpus is deleted once at suite start (test_helper.exs), so these deletes
  # are no-ops that never contend on corpus rows.
  def reset_committed_catalog_in_sandbox! do
    with_committed_catalog_fixture_lock(fn ->
      delete_all_tables!(@tables)
    end)
  end

  def reset_committed_ingestion_control_plane_in_sandbox! do
    with_committed_catalog_fixture_lock(fn ->
      delete_all_tables!(@ingestion_control_plane_tables)
    end)
  end

  # Full-corpus clear for test files that need a clean view: serialized under
  # the fixture lock so concurrent full-table DELETEs never contend on the
  # same rows (which would trip Ecto's default 15s query timeout).
  def clear_catalog_in_sandbox! do
    with_committed_catalog_fixture_lock(fn ->
      delete_all_tables!(@tables)
    end)
  end

  def reset_committed_catalog_with_fixtures! do
    with_committed_catalog_fixture_lock(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        delete_all_tables!(@tables)
        seed_committed_catalog_fixtures!()
      end)
    end)

    clear_public_catalog_cache!()
  end

  def ensure_committed_catalog_fixtures! do
    with_committed_catalog_fixture_lock(fn ->
      Sandbox.unboxed_run(Repo, fn -> seed_committed_catalog_if_needed!() end)
    end)

    clear_public_catalog_cache!()
  end

  defp seed_committed_catalog_if_needed! do
    unless committed_catalog_seeded?() do
      lock_id = acquire_full_corpus_seed_lock!()

      try do
        delete_all_tables!(@tables)
        seed_committed_catalog_fixtures!()
      after
        release_full_corpus_seed_lock(lock_id)
      end
    end
  end

  def committed_catalog_fixtures_ready? do
    Sandbox.unboxed_run(Repo, &committed_catalog_seeded?/0)
  end

  def reset_committed_ingestion_control_plane! do
    with_committed_catalog_fixture_lock(fn ->
      reset_committed_tables!(@ingestion_control_plane_tables)
    end)
  end

  def clear_catalog!, do: :ok

  defp with_committed_catalog_fixture_lock(fun) when is_function(fun, 0) do
    # OTP 28 :global locks are exclusive per ResourceId and reentrant per
    # LockRequesterId: a fixed requester id is SHARED across processes, so the
    # caller must carry its own unique requester id to serialize.
    :global.trans(
      {{__MODULE__, :committed_catalog_fixtures}, {self(), System.unique_integer([:positive])}},
      fun,
      [node()],
      :infinity
    )
  end

  # Serializes FULL-corpus imports (the importer giant tests and the committed
  # corpus reseed). Two concurrent full-corpus imports run find_or_create on
  # the same contributors and deadlock on the unique-index ShareLocks (40P01),
  # so they must never overlap.
  def acquire_full_corpus_seed_lock! do
    lock_id = {
      @full_corpus_seed_lock,
      {self(), System.unique_integer([:positive])}
    }

    :global.set_lock(lock_id, [node()], :infinity)
    lock_id
  end

  def release_full_corpus_seed_lock(lock_id) do
    :global.del_lock(lock_id, [node()])
  end

  def with_full_corpus_seed_lock(fun) when is_function(fun, 0) do
    lock_id = acquire_full_corpus_seed_lock!()

    try do
      fun.()
    after
      release_full_corpus_seed_lock(lock_id)
    end
  end

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
    Sandbox.unboxed_run(Repo, fn -> delete_all_tables!(tables) end)
  end

  # DELETE (ROW EXCLUSIVE, per-row) instead of TRUNCATE (ACCESS EXCLUSIVE):
  # concurrent sandbox transactions hold ACCESS SHARE / ROW EXCLUSIVE locks
  # that TRUNCATE waits on while already holding locks later-needed by those
  # transactions (lock cycle -> 40P01). DELETE is compatible with ACCESS
  # SHARE and only contends per-row, and the child-first @tables order keeps
  # row-lock acquisition identical across concurrent resets.
  defp delete_all_tables!(tables) do
    for table <- tables do
      Repo.query!("DELETE FROM #{table}", [], timeout: :infinity)
    end

    :ok
  end
end
