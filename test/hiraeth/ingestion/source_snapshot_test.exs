defmodule Hiraeth.Ingestion.SourceSnapshotTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Ingestion.{ProviderRun, ProviderSource, SourceSnapshot}

  @actor %{id: "catalog-writer-fixture", catalog_write?: true}
  @fetched_at ~U[2026-06-01 12:00:00Z]

  setup do
    previous_root = Application.get_env(:hiraeth, :source_snapshot_retention_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-source-snapshot-test-#{System.unique_integer([:positive])}"
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

  test "creates and reads source snapshot metadata with a retained artifact", %{
    retention_root: root
  } do
    source = create_provider_source!()
    run = create_provider_run!(source)
    payload = ~s({"books":[{"title":"Fixture Book"}]})

    artifact =
      SourceSnapshot.retain_artifact!("test-provider", "https://example.com/books", payload,
        extension: ".json",
        retention_root: root
      )

    snapshot =
      SourceSnapshot
      |> Ash.Changeset.for_create(:create, %{
        provider_source_id: source.id,
        provider_run_id: run.id,
        provider: "test-provider",
        source_url: "https://example.com/books",
        checksum: artifact.checksum,
        fetched_at: @fetched_at,
        http_metadata: %{
          "status" => 200,
          "headers" => %{"content-type" => ["application/json"]}
        },
        adapter_version: "sidecar-test-v1",
        source_mode: "scrape",
        artifact_path: artifact.artifact_path,
        byte_size: artifact.byte_size
      })
      |> Ash.create!(actor: @actor)

    assert snapshot.provider == "test-provider"
    assert snapshot.source_url == "https://example.com/books"
    assert snapshot.source_uri == "https://example.com/books"
    assert snapshot.checksum == artifact.checksum
    assert snapshot.content_checksum == artifact.checksum
    assert snapshot.http_metadata["status"] == 200
    assert snapshot.adapter_version == "sidecar-test-v1"
    assert snapshot.source_mode == "scrape"
    assert snapshot.artifact_path == artifact.artifact_path
    assert snapshot.storage_ref == artifact.artifact_path
    assert snapshot.byte_size == byte_size(payload)
    assert snapshot.raw_payload == %{}

    read_snapshot =
      SourceSnapshot
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.id == snapshot.id))

    assert read_snapshot.id == snapshot.id
    assert SourceSnapshot.load_payload!(read_snapshot, retention_root: root) == payload
  end

  test "replay loads current retained payload by snapshot path", %{retention_root: root} do
    source = create_provider_source!()
    run = create_provider_run!(source)
    original_payload = ~s({"books":[{"title":"Original"}]})

    artifact =
      SourceSnapshot.retain_artifact!(
        "test-provider",
        "https://example.com/books",
        original_payload,
        extension: ".json",
        retention_root: root
      )

    snapshot =
      SourceSnapshot
      |> Ash.Changeset.for_create(:create, %{
        provider_source_id: source.id,
        provider_run_id: run.id,
        provider: "test-provider",
        source_url: "https://example.com/books",
        checksum: artifact.checksum,
        fetched_at: @fetched_at,
        source_mode: "api",
        artifact_path: artifact.artifact_path
      })
      |> Ash.create!(actor: @actor)

    replacement_payload = ~s({"books":[{"title":"Replacement"}]})
    absolute_path = Path.join(root, snapshot.artifact_path)
    File.write!(absolute_path, replacement_payload)

    assert SourceSnapshot.load_payload!(snapshot, retention_root: root) == replacement_payload
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
      requested_by: "source_snapshot_test",
      run_key: "test-provider-2026-06-01T12:00:00Z"
    })
    |> Ash.create!(actor: @actor)
  end
end
