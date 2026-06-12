defmodule HiraethWeb.AdminImportLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Hiraeth.Accounts.User
  alias Hiraeth.Catalog.{Edition, Identifier}
  alias Hiraeth.Imports.{ImportRun, ReviewItem, StagedImportRow}

  @password "correct horse battery staple"

  test "non-admin visitors are redirected away from import workflow", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/imports")
  end

  test "admin uploads, maps, dry-runs, and applies a valid CSV", %{conn: conn} do
    %{conn: conn, admin: admin} = signed_in_import_context(conn)
    before_count = Edition |> Ash.read!(authorize?: false) |> length()

    assert {:ok, view, html} = live(conn, ~p"/admin/imports/new")
    assert html =~ "New CSV import"

    upload =
      file_input(view, "#import-upload-form", :csv, [
        %{
          name: "ten_books.csv",
          content: File.read!("test/fixtures/imports/ten_books.csv"),
          type: "text/csv"
        }
      ])

    assert render_upload(upload, "ten_books.csv") =~ "ten_books.csv"

    view
    |> form("#import-upload-form", %{"import_upload" => %{"provider" => "live_valid_#{admin.id}"}})
    |> render_submit()

    run = import_run_by_provider!("live_valid_#{admin.id}")
    assert Enum.count(rows_for(run)) == 10

    assert {:ok, detail, detail_html} = live(conn, ~p"/admin/imports/#{run.id}")
    assert detail_html =~ "Mapping"

    detail
    |> form("#mapping-form", %{
      "mapping" => %{"title" => "title", "isbn" => "isbn", "publisher" => "publisher"}
    })
    |> render_submit()

    detail |> element("#dry-run-import") |> render_click()
    assert Ash.reload!(run, authorize?: false).status == "dry_run"
    assert before_count == Edition |> Ash.read!(authorize?: false) |> length()
    assert render(detail) =~ "Accepted: 10"
    assert render(detail) =~ "Needs review: 0"

    detail |> element("#apply-import") |> render_click()
    assert Ash.reload!(run, authorize?: false).status == "applied"
    assert Enum.any?(Ash.read!(Edition, authorize?: false), &(&1.title == "Import Book 10"))
    assert Enum.any?(Ash.read!(Identifier, authorize?: false), &(&1.value == "9787100000010"))
  end

  test "malformed, over-limit, and duplicate ISBN CSVs surface reviewable errors", %{conn: conn} do
    %{conn: conn, admin: admin} = signed_in_import_context(conn)

    assert {:ok, malformed_view, _html} = live(conn, ~p"/admin/imports/new")

    malformed_upload =
      file_input(malformed_view, "#import-upload-form", :csv, [
        %{
          name: "malformed.csv",
          content: "title,isbn\n\"Unclosed,9787100000020\n",
          type: "text/csv"
        }
      ])

    assert render_upload(malformed_upload, "malformed.csv") =~ "malformed.csv"

    malformed_html =
      malformed_view
      |> form("#import-upload-form", %{"import_upload" => %{"provider" => "live_bad_#{admin.id}"}})
      |> render_submit()

    assert malformed_html =~ "malformed CSV"

    assert {:ok, oversized_view, _html} = live(conn, ~p"/admin/imports/new")

    oversized_upload =
      file_input(oversized_view, "#import-upload-form", :csv, [
        %{name: "too-large.csv", content: String.duplicate("x", 1_048_577), type: "text/csv"}
      ])

    assert render_upload(oversized_upload, "too-large.csv") =~ "too-large.csv"

    oversized_html =
      oversized_view
      |> form("#import-upload-form", %{
        "import_upload" => %{"provider" => "live_large_#{admin.id}"}
      })
      |> render_submit()

    assert oversized_html =~ "1 MiB"

    duplicate_csv =
      "title,isbn,publisher\nGood,9787100000030,Press\nMissing ISBN,,Press\nDup,9787100000030,Press\n"

    assert {:ok, duplicate_view, _html} = live(conn, ~p"/admin/imports/new")

    duplicate_upload =
      file_input(duplicate_view, "#import-upload-form", :csv, [
        %{name: "duplicate.csv", content: duplicate_csv, type: "text/csv"}
      ])

    assert render_upload(duplicate_upload, "duplicate.csv") =~ "duplicate.csv"

    duplicate_view
    |> form("#import-upload-form", %{"import_upload" => %{"provider" => "live_dup_#{admin.id}"}})
    |> render_submit()

    run = import_run_by_provider!("live_dup_#{admin.id}")
    assert {:ok, detail, _html} = live(conn, ~p"/admin/imports/#{run.id}")

    detail
    |> form("#mapping-form", %{
      "mapping" => %{"title" => "title", "isbn" => "isbn", "publisher" => "publisher"}
    })
    |> render_submit()

    detail |> element("#dry-run-import") |> render_click()
    assert render(detail) =~ "Accepted: 1"
    assert render(detail) =~ "Needs review: 2"
    assert has_element?(detail, "a[href^='/admin/review/']")
    assert Enum.count(review_items_for(run)) == 2
  end

  test "apply keeps canonical catalog unchanged when accepted row application rolls back", %{
    conn: conn
  } do
    %{conn: conn, admin: admin} = signed_in_import_context(conn)

    rollback_csv =
      "title,isbn,publisher\nBefore Failure,9787100000040,Press\nROLLBACK,9787100000041,Press\n"

    assert {:ok, view, _html} = live(conn, ~p"/admin/imports/new")

    upload =
      file_input(view, "#import-upload-form", :csv, [
        %{name: "rollback.csv", content: rollback_csv, type: "text/csv"}
      ])

    assert render_upload(upload, "rollback.csv") =~ "rollback.csv"

    view
    |> form("#import-upload-form", %{
      "import_upload" => %{"provider" => "live_rollback_#{admin.id}"}
    })
    |> render_submit()

    run = import_run_by_provider!("live_rollback_#{admin.id}")
    assert {:ok, detail, _html} = live(conn, ~p"/admin/imports/#{run.id}")

    detail
    |> form("#mapping-form", %{
      "mapping" => %{"title" => "title", "isbn" => "isbn", "publisher" => "publisher"}
    })
    |> render_submit()

    detail |> element("#dry-run-import") |> render_click()
    assert render(detail) =~ "Accepted: 2"

    html = detail |> element("#apply-import") |> render_click()
    assert html =~ "rollback sentinel"
    refute Enum.any?(Ash.read!(Edition, authorize?: false), &(&1.title == "Before Failure"))
    refute Enum.any?(Ash.read!(Edition, authorize?: false), &(&1.title == "ROLLBACK"))
  end

  test "admin mapping controls import non-standard source headers", %{conn: conn} do
    %{conn: conn, admin: admin} = signed_in_import_context(conn)
    csv = "book_title,book_isbn,press\nMapped Live Book,9787100000050,Mapped Live Press\n"

    assert {:ok, view, _html} = live(conn, ~p"/admin/imports/new")

    upload =
      file_input(view, "#import-upload-form", :csv, [
        %{name: "mapped.csv", content: csv, type: "text/csv"}
      ])

    assert render_upload(upload, "mapped.csv") =~ "mapped.csv"

    view
    |> form("#import-upload-form", %{
      "import_upload" => %{"provider" => "live_mapped_#{admin.id}"}
    })
    |> render_submit()

    run = import_run_by_provider!("live_mapped_#{admin.id}")
    assert {:ok, detail, _html} = live(conn, ~p"/admin/imports/#{run.id}")

    detail
    |> form("#mapping-form", %{
      "mapping" => %{"title" => "book_title", "isbn" => "book_isbn", "publisher" => "press"}
    })
    |> render_submit()

    detail |> element("#dry-run-import") |> render_click()
    assert render(detail) =~ "Accepted: 1"
    assert render(detail) =~ "Needs review: 0"
    assert render(detail) =~ "Mapped Live Book"
    assert render(detail) =~ "ISBN 9787100000050"

    detail
    |> form("#mapping-form", %{
      "mapping" => %{"title" => "book_title", "isbn" => "book_isbn", "publisher" => "press"}
    })
    |> render_submit()

    assert render(detail) =~ "Mapped Live Book"

    detail |> element("#apply-import") |> render_click()
    assert Enum.any?(Ash.read!(Edition, authorize?: false), &(&1.title == "Mapped Live Book"))
    assert Enum.any?(Ash.read!(Identifier, authorize?: false), &(&1.value == "9787100000050"))
  end

  defp signed_in_import_context(conn) do
    admin =
      User
      |> Ash.Changeset.for_create(:seed_admin, %{
        email: "import-live-#{System.unique_integer([:positive])}@example.test",
        password: @password,
        display_name: "Import Live Admin"
      })
      |> Ash.create!(authorize?: false)

    signed_in =
      User
      |> Ash.Query.for_read(:sign_in_with_password, %{email: admin.email, password: @password})
      |> Ash.read_one!()

    %{
      conn:
        conn
        |> init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(signed_in),
      admin: admin
    }
  end

  defp import_run_by_provider!(provider) do
    ImportRun
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.provider == provider))
  end

  defp rows_for(run) do
    StagedImportRow
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.import_run_id == run.id))
  end

  defp review_items_for(run) do
    ReviewItem
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.import_run_id == run.id))
  end
end
