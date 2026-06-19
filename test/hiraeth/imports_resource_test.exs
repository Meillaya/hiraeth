defmodule Hiraeth.ImportsResourceTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Catalog.{Edition, Identifier}
  alias Hiraeth.Imports.{ImportMapping, ImportRun, ReviewItem, StagedImportRow}
  alias Hiraeth.Sources.SourceRecord

  setup do
    %{admin: trusted_catalog_actor()}
  end

  test "valid CSV supports quoted fields with commas", %{admin: admin} do
    csv = ~s(title,isbn,publisher
"Title, With Comma",9787000000099,"Comma, Press"
)
    run = upload!(csv, admin)

    assert [%{raw_payload: %{"title" => "Title, With Comma", "publisher" => "Comma, Press"}}] =
             staged_rows(run)

    run = run |> map_columns!(admin) |> validate!(admin) |> apply_run!(admin)
    assert run.status == "applied"
    assert Enum.any?(Ash.read!(Edition, authorize?: false), &(&1.title == "Title, With Comma"))
  end

  test "column mappings drive validation and apply for non-standard CSV headers", %{admin: admin} do
    csv = "book_title,book_isbn,press\nMapped Book,9787000000100,Mapped Press\n"
    run = upload!(csv, admin)

    run =
      run
      |> map_columns!(admin, %{
        "book_title" => "title",
        "book_isbn" => "isbn",
        "press" => "publisher"
      })
      |> validate!(admin)

    assert [%{status: "accepted"}] = staged_rows(run)
    assert review_items(run) == []

    run |> dry_run!(admin) |> apply_run!(admin)

    assert Enum.any?(Ash.read!(Edition, authorize?: false), &(&1.title == "Mapped Book"))
    assert Enum.any?(Ash.read!(Identifier, authorize?: false), &(&1.value == "9787000000100"))
  end

  test "column mappings can be resaved for the same run without stale duplicates", %{admin: admin} do
    run = upload!("book_title,book_isbn,press\nMapped Again,9787000000101,Mapped Press\n", admin)

    run =
      map_columns!(run, admin, %{
        "book_title" => "title",
        "book_isbn" => "isbn",
        "press" => "publisher"
      })

    run =
      map_columns!(run, admin, %{
        "book_title" => "title",
        "book_isbn" => "isbn",
        "press" => "publisher"
      })

    assert Enum.count(mappings(run)) == 3
    assert validate!(run, admin).status == "validated"
  end

  test "valid CSV uploads, maps, validates, dry-runs without canonical writes, and applies", %{
    admin: admin
  } do
    csv = "title,isbn,publisher\nImported Book,9787000000001,Import Press\n"
    run = upload!(csv, admin)

    assert run.status == "uploaded"
    assert [%{raw_payload: %{"title" => "Imported Book"}}] = staged_rows(run)

    run = map_columns!(run, admin)

    assert Enum.any?(
             mappings(run),
             &match?(%ImportMapping{source_column: "title", target_field: "title"}, &1)
           )

    run = validate!(run, admin)
    assert run.status == "validated"
    assert review_items(run) == []

    run = dry_run!(run, admin)
    assert run.status == "dry_run"
    refute Enum.any?(Ash.read!(Edition, authorize?: false), &(&1.title == "Imported Book"))

    run = apply_run!(run, admin)
    assert run.status == "applied"
    assert Enum.any?(Ash.read!(Edition, authorize?: false), &(&1.title == "Imported Book"))
    assert Enum.any?(Ash.read!(Identifier, authorize?: false), &(&1.value == "9787000000001"))
  end

  test "malformed, partial bad, duplicate, and over-limit CSV are rejected or staged for review",
       %{
         admin: admin
       } do
    assert {:error, malformed} = upload("title,isbn\n\"Unclosed,9787000000002\n", admin)
    assert Exception.message(malformed) =~ "malformed CSV"

    oversized = String.duplicate("x", 1_048_577)
    assert {:error, too_large} = upload(oversized, admin)
    assert Exception.message(too_large) =~ "1 MiB"

    too_many_rows =
      "title,isbn,publisher\n" <> String.duplicate("Book,9787000000003,Press\n", 251)

    assert {:error, too_many} = upload(too_many_rows, admin)
    assert Exception.message(too_many) =~ "250 rows"

    csv =
      "title,isbn,publisher\nGood,9787000000004,Press\nMissing ISBN,,Press\nDup,9787000000004,Press\n"

    run = csv |> upload!(admin) |> map_columns!(admin) |> validate!(admin)

    rows = staged_rows(run)
    assert Enum.count(rows, &(&1.status == "accepted")) == 1
    assert Enum.count(rows, &(&1.status == "needs_review")) == 2
    assert Enum.any?(review_items(run), &(&1.message =~ "missing isbn"))
    assert Enum.any?(review_items(run), &(&1.message =~ "duplicate isbn"))
  end

  test "apply rolls back canonical writes on failure and rows can be rejected/approved", %{
    admin: admin
  } do
    csv =
      "title,isbn,publisher\nBefore Failure,9787000000005,Press\nROLLBACK,9787000000006,Press\n"

    run = csv |> upload!(admin) |> map_columns!(admin) |> validate!(admin)

    assert {:error, error} = apply_run(run, admin)
    assert Exception.message(error) =~ "rollback sentinel"
    refute Enum.any?(Ash.read!(Edition, authorize?: false), &(&1.title == "Before Failure"))

    row = hd(staged_rows(run))

    rejected =
      row
      |> Ash.Changeset.for_update(:reject_row, %{reason: "not in catalog"})
      |> Ash.update!(actor: admin)

    assert rejected.status == "rejected"

    item =
      hd(review_items(validate!(upload!("title,isbn,publisher\nBad,,Press\n", admin), admin)))

    approved =
      item
      |> Ash.Changeset.for_update(:approve_review_item)
      |> Ash.update!(actor: admin)

    assert approved.decision == "approved"
  end

  test "applied CSV provenance preserves actual provider and import run lineage", %{admin: admin} do
    csv = "title,isbn,publisher\nProvider Book,9787000000102,Provider Press\n"

    run =
      csv
      |> upload!(admin, "actual_provider")
      |> map_columns!(admin)
      |> validate!(admin)
      |> apply_run!(admin)

    source_record =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.import_run_id == run.id))

    assert source_record.provider == "actual_provider"
    assert source_record.source_uri =~ "actual_provider:import_run:#{run.id}:edition:"
    assert source_record.raw_payload["import_run_id"] == run.id
  end

  test "writes require trusted catalog writer and no background job dependency is present", %{
    admin: admin
  } do
    assert {:error, error} = upload("title,isbn,publisher\nNope,9787000000007,Press\n", nil)
    assert Exception.message(error) =~ "forbidden"

    assert upload!("title,isbn,publisher\nYep,9787000000008,Press\n", admin)
  end

  defp upload!(csv, actor, provider \\ "local_csv"), do: upload(csv, actor, provider) |> ok!()

  defp upload(csv, actor, provider \\ "local_csv") do
    ImportRun
    |> Ash.Changeset.for_create(:upload_csv, %{
      provider: provider,
      file_name: "catalog.csv",
      csv_content: csv
    })
    |> Ash.create(actor: actor)
  end

  defp map_columns!(run, actor) do
    map_columns!(run, actor, %{"title" => "title", "isbn" => "isbn", "publisher" => "publisher"})
  end

  defp map_columns!(run, actor, mappings) do
    run
    |> Ash.Changeset.for_update(:map_columns, %{
      mappings: mappings
    })
    |> Ash.update!(actor: actor)
  end

  defp validate!(run, actor) do
    run
    |> Ash.Changeset.for_update(:validate_rows)
    |> Ash.update!(actor: actor)
  end

  defp dry_run!(run, actor) do
    run
    |> Ash.Changeset.for_update(:dry_run)
    |> Ash.update!(actor: actor)
  end

  defp apply_run!(run, actor), do: apply_run(run, actor) |> ok!()

  defp apply_run(run, actor) do
    run
    |> Ash.Changeset.for_update(:apply_accepted_rows)
    |> Ash.update(actor: actor)
  end

  defp staged_rows(run),
    do:
      StagedImportRow
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.import_run_id == run.id))

  defp mappings(run),
    do:
      ImportMapping |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.import_run_id == run.id))

  defp review_items(run),
    do: ReviewItem |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.import_run_id == run.id))

  defp ok!({:ok, result}), do: result
end
