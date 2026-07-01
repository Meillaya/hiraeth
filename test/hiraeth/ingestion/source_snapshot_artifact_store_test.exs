defmodule Hiraeth.Ingestion.SourceSnapshotArtifactStoreTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Ingestion.{ProviderRun, ProviderSource, SourceSnapshot}

  @actor %{id: "catalog-writer-fixture", catalog_write?: true}
  @fetched_at ~U[2026-06-01 12:00:00Z]
  @safe_artifact_path "source-snapshots/test-provider/example/fixture.json"

  setup do
    previous_root = Application.get_env(:hiraeth, :source_snapshot_retention_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-source-snapshot-artifact-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:hiraeth, :source_snapshot_retention_root, root)

    on_exit(fn ->
      if previous_root do
        Application.put_env(:hiraeth, :source_snapshot_retention_root, previous_root)
      else
        Application.delete_env(:hiraeth, :source_snapshot_retention_root)
      end

      File.rm_rf!(root)
    end)

    {:ok, retention_root: root}
  end

  test "checksum changes when retained payload changes", %{retention_root: root} do
    first =
      SourceSnapshot.retain_artifact!(
        "test-provider",
        "https://example.com/books",
        "first payload",
        retention_root: root
      )

    second =
      SourceSnapshot.retain_artifact!(
        "test-provider",
        "https://example.com/books",
        "second payload",
        retention_root: root
      )

    assert first.checksum != second.checksum

    assert SourceSnapshot.load_payload!(first.artifact_path, retention_root: root) ==
             "first payload"

    assert SourceSnapshot.load_payload!(second.artifact_path, retention_root: root) ==
             "second payload"
  end

  test "rejects traversal, absolute, and public artifact paths" do
    source = create_provider_source!()
    run = create_provider_run!(source)

    for unsafe_path <- unsafe_artifact_paths() do
      assert {:error, error} =
               SourceSnapshot
               |> Ash.Changeset.for_create(:create, %{
                 provider_source_id: source.id,
                 provider_run_id: run.id,
                 provider: "test-provider",
                 source_url: "https://example.com/books",
                 artifact_path: unsafe_path,
                 checksum: "sha256:abc",
                 fetched_at: @fetched_at,
                 source_mode: "scrape"
               })
               |> Ash.create(actor: @actor)

      assert Exception.message(error) =~ "artifact_path"
      assert Exception.message(error) =~ "private retention root"
    end
  end

  test "rejects unsafe storage_ref even when artifact_path is safe" do
    source = create_provider_source!()
    run = create_provider_run!(source)

    for unsafe_path <- unsafe_artifact_paths() do
      assert {:error, error} =
               SourceSnapshot
               |> Ash.Changeset.for_create(:create, %{
                 provider_source_id: source.id,
                 provider_run_id: run.id,
                 provider: "test-provider",
                 source_url: "https://example.com/books",
                 artifact_path: @safe_artifact_path,
                 storage_ref: unsafe_path,
                 checksum: "sha256:abc",
                 fetched_at: @fetched_at,
                 source_mode: "scrape"
               })
               |> Ash.create(actor: @actor)

      message = Exception.message(error)
      assert message =~ "storage_ref"
      assert message =~ "private retention root"
    end
  end

  test "rejects conflicting alias values" do
    source = create_provider_source!()
    run = create_provider_run!(source)

    assert_create_error(
      %{
        provider_source_id: source.id,
        provider_run_id: run.id,
        provider: "test-provider",
        source_url: "https://example.com/books",
        source_uri: "https://example.com/other-books",
        artifact_path: @safe_artifact_path,
        checksum: "sha256:abc",
        fetched_at: @fetched_at,
        source_mode: "scrape"
      },
      "source_url"
    )

    assert_create_error(
      %{
        provider_source_id: source.id,
        provider_run_id: run.id,
        provider: "test-provider",
        source_url: "https://example.com/books",
        artifact_path: @safe_artifact_path,
        checksum: "sha256:abc",
        content_checksum: "sha256:def",
        fetched_at: @fetched_at,
        source_mode: "scrape"
      },
      "checksum"
    )

    assert_create_error(
      %{
        provider_source_id: source.id,
        provider_run_id: run.id,
        provider: "test-provider",
        source_url: "https://example.com/books",
        artifact_path: @safe_artifact_path,
        storage_ref: "source-snapshots/test-provider/example/other.json",
        checksum: "sha256:abc",
        fetched_at: @fetched_at,
        source_mode: "scrape"
      },
      "artifact_path"
    )
  end

  defp unsafe_artifact_paths do
    [
      "../../escape.json",
      "/tmp/escape.json",
      "priv/static/uploads/escape.json"
    ]
  end

  defp create_provider_source! do
    ProviderSource
    |> Ash.Changeset.for_create(:create, %{
      stable_source_key: "publisher:test-provider:manifest",
      provider_name: "Test Provider",
      source_kind: "publisher",
      ingestion_mode: "scrape",
      base_uri: "https://example.com/",
      allowed_hosts: ["example.com"],
      enabled?: true
    })
    |> Ash.create!(actor: @actor)
  end

  defp create_provider_run!(source) do
    ProviderRun
    |> Ash.Changeset.for_create(:create, %{
      provider_source_id: source.id,
      status: "queued",
      requested_by: "source_snapshot_artifact_store_test",
      run_key: "test-provider-2026-06-01T12:00:00Z"
    })
    |> Ash.create!(actor: @actor)
  end

  defp assert_create_error(params, expected_message) do
    assert {:error, error} =
             SourceSnapshot
             |> Ash.Changeset.for_create(:create, params)
             |> Ash.create(actor: @actor)

    assert Exception.message(error) =~ expected_message
  end
end
