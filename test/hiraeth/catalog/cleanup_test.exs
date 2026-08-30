defmodule Hiraeth.CatalogCleanupTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Hiraeth.Catalog.TinyCommittedFixture
  alias Hiraeth.CatalogCleanup
  alias Hiraeth.RealCatalog.{Dataset, SourceArtifacts}
  alias Hiraeth.Repo

  setup do
    CatalogCleanup.reset_committed_catalog!()
    on_exit(fn -> CatalogCleanup.reset_committed_catalog!() end)
  end

  test "committed catalog verifier rejects partial state the legacy sentinel accepted" do
    insert_legacy_sentinel_only!()

    assert source_record_count() == 1
    refute CatalogCleanup.committed_catalog_fixtures_ready?()
  end

  @tag :full_catalog
  @tag :slow
  # Fast reseed contract: the body seeds the TINY TinyCommittedFixture (1
  # record) via use_tiny_committed_catalog_fixture!, so this runs in seconds.
  # The slow-lane importer tests (real_catalog_importer_test.exs) cover the
  # committed-corpus reseed path.
  @tag timeout: 120_000
  test "ensure_committed_catalog_fixtures! reseeds partial state and reuses a real importer fixture equivalent" do
    use_tiny_committed_catalog_fixture!()
    insert_legacy_sentinel_only!()

    assert source_record_count() == 1
    refute CatalogCleanup.committed_catalog_fixtures_ready?()

    CatalogCleanup.ensure_committed_catalog_fixtures!()

    assert CatalogCleanup.committed_catalog_fixtures_ready?(),
           "expected ready after reseed, got db=#{inspect(committed_catalog_summary())} expected=#{inspect(expected_catalog_summary())}"

    assert committed_catalog_summary() == expected_catalog_summary()

    seeded_import_run_ids = import_run_ids()
    seeded_source_record_count = source_record_count()

    CatalogCleanup.ensure_committed_catalog_fixtures!()

    assert CatalogCleanup.committed_catalog_fixtures_ready?(),
           "expected ready after idempotent ensure, got db=#{inspect(committed_catalog_summary())} expected=#{inspect(expected_catalog_summary())}"

    assert committed_catalog_summary() == expected_catalog_summary()
    assert import_run_ids() == seeded_import_run_ids
    assert source_record_count() == seeded_source_record_count
  end

  test "reset_committed_catalog! waits for the committed fixture lock" do
    caller = self()

    # OTP 28 :global locks are exclusive per ResourceId and reentrant per
    # LockRequesterId, so the holder carries its own unique requester id.
    lock_resource_id = {CatalogCleanup, :committed_catalog_fixtures}

    holder =
      Task.async(fn ->
        :global.trans(
          {lock_resource_id, {self(), :lock_holder}},
          fn ->
            send(caller, :fixture_lock_acquired)

            receive do
              :release_fixture_lock -> :ok
            end
          end,
          [node()],
          :infinity
        )
      end)

    assert_receive :fixture_lock_acquired

    resetter = Task.async(fn -> CatalogCleanup.reset_committed_catalog!() end)

    assert Task.yield(resetter, 100) == nil

    send(holder.pid, :release_fixture_lock)

    assert :ok = Task.await(holder, 5_000)
    assert :ok = Task.await(resetter, 5_000)
  end

  defp insert_legacy_sentinel_only! do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "TRUNCATE TABLE source_records, editions, works, imprints, publishers RESTART IDENTITY CASCADE"
      )

      %{rows: [[publisher_id]]} =
        Repo.query!("insert into publishers (name, slug) values ($1, $2) returning id", [
          "Deep Vellum",
          "deep-vellum"
        ])

      %{rows: [[work_id]]} =
        Repo.query!(
          "insert into works (title, slug, publication_state) values ($1, $2, $3) returning id",
          ["Immigrant", "deep-vellum-immigrant", "published"]
        )

      %{rows: [[edition_id]]} =
        Repo.query!(
          """
          insert into editions (title, slug, format, work_id, publisher_id)
          values ($1, $2, $3, $4, $5)
          returning id
          """,
          [
            "Immigrant",
            "deep-vellum-immigrant-paperback-9781646054541",
            "paperback",
            work_id,
            publisher_id
          ]
        )

      Repo.query!(
        """
        insert into source_records
          (provider, source_type, source_uri, file_checksum, license_note, raw_payload, imported_at, source_identity, edition_id)
        values
          ($1, $2, $3, $4, $5, $6, date_trunc('second', now()), $7, $8)
        """,
        [
          "deep_vellum_official_store",
          "publisher_dataset",
          "https://store.deepvellum.org/products/immigrant",
          "legacy-partial-checksum",
          "test",
          %{},
          "isbn:9781646054541",
          edition_id
        ]
      )
    end)
  end

  defp committed_catalog_summary do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        """
        select provider, file_checksum, count(*), count(edition_id)
        from source_records
        where source_type = 'publisher_dataset'
        group by provider, file_checksum
        order by provider, file_checksum
        """,
        []
      ).rows
    end)
  end

  defp expected_catalog_summary do
    expected_entries()
    |> Enum.group_by(&{&1["provider"], &1["dataset_sha256"]})
    |> Enum.map(fn {{provider, checksum}, entries} ->
      [provider, checksum, length(entries), length(entries)]
    end)
    |> Enum.sort()
  end

  defp source_record_count do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[count]]} = Repo.query!("select count(*) from source_records", [])
      count
    end)
  end

  defp import_run_ids do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: rows} = Repo.query!("select id from import_runs order by provider, id", [])
      Enum.map(rows, fn [id] -> id end)
    end)
  end

  defp use_tiny_committed_catalog_fixture! do
    tmp = TinyCommittedFixture.create!()
    previous = Application.get_env(:hiraeth, :committed_catalog_fixture_dir)
    Application.put_env(:hiraeth, :committed_catalog_fixture_dir, tmp)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:hiraeth, :committed_catalog_fixture_dir)
      else
        Application.put_env(:hiraeth, :committed_catalog_fixture_dir, previous)
      end

      File.rm_rf!(tmp)
    end)
  end

  defp committed_catalog_fixture_dir do
    Application.get_env(:hiraeth, :committed_catalog_fixture_dir, Dataset.default_dir())
  end

  defp expected_entries do
    {:ok, manifest} = SourceArtifacts.build_manifest(committed_catalog_fixture_dir())

    manifest["artifacts"]
    |> Enum.flat_map(fn artifact ->
      Enum.map(artifact["source_record_entries"], fn entry ->
        Map.merge(entry, %{
          "provider" => artifact["provider"],
          "dataset_sha256" => artifact["dataset_sha256"]
        })
      end)
    end)
  end
end
