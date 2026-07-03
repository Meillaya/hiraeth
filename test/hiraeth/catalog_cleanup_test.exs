defmodule Hiraeth.CatalogCleanupTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
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
    tmp = tiny_committed_catalog_dir!()
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

  defp tiny_committed_catalog_dir! do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-tiny-committed-catalog-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    provider = "archipelago_books_official_store"
    source_uri = "https://archipelagobooks.org/book/tiny-committed-catalog/"

    field_source = %{
      provider: provider,
      source_uri: source_uri,
      source_type: "publisher_dataset",
      rights_basis: "Deterministic committed catalog fixture equivalent for test-only metadata."
    }

    payload = %{
      provider: provider,
      retrieved_at: "2026-07-02T00:00:00Z",
      license_note: "Deterministic committed catalog fixture equivalent for test-only metadata.",
      provider_permissions: %{
        provider: provider,
        source_urls: [source_uri],
        source_hosts: ["archipelagobooks.org"],
        cover_hosts: ["archipelagobooks.org", "covers.openlibrary.org"],
        permission_basis:
          "Deterministic committed catalog fixture equivalent for test-only metadata.",
        cover_cache_policy: "cache_allowed",
        excluded_content: ["cart_checkout_account", "inventory_state", "user_reviews"],
        takedown_contact: "https://archipelagobooks.org/contact/",
        not_legal_advice: "Test fixture metadata only; not legal advice."
      },
      records: [
        %{
          source_uri: source_uri,
          source_product_id: "tiny-committed-catalog-9781939810175",
          source_sku: "9781939810175",
          publisher: "Archipelago Books",
          imprint: nil,
          work: %{
            title: "Tiny Committed Catalog",
            subtitle: nil,
            publication_state: "published"
          },
          edition: %{
            title: "Tiny Committed Catalog",
            subtitle: nil,
            format: "paperback",
            published_on: "2026-07-02",
            isbn_13: "9781939810175"
          },
          contributors: [%{name: "Fixture Author", role: "author"}],
          displayed_fields: [
            "title",
            "contributors",
            "publisher",
            "format",
            "published_on",
            "isbn_13"
          ],
          curation: %{
            status: "approved",
            notes: "Deterministic tiny committed catalog fixture equivalent."
          },
          no_cover_reason: "Tiny committed fixture intentionally omits covers.",
          field_sources: %{
            "title" => field_source,
            "contributors" => field_source,
            "publisher" => field_source,
            "format" => field_source,
            "published_on" => field_source,
            "isbn_13" => field_source
          }
        }
      ]
    }

    authority_manifest = %{
      providers: [
        %{
          provider: provider,
          coverage: %{expected_record_count: 1},
          allowed_source_urls: [source_uri],
          allowed_source_types: ["publisher_dataset"],
          max_bytes: %{response: 100_000}
        }
      ],
      completeness_boundary: "deterministic test-only committed catalog equivalent"
    }

    File.write!(
      Path.join(tmp, "tiny_committed_catalog.json"),
      Jason.encode!(payload, pretty: true)
    )

    File.write!(
      Path.join(tmp, Dataset.source_authority_manifest_file()),
      Jason.encode!(authority_manifest, pretty: true)
    )

    tmp
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
