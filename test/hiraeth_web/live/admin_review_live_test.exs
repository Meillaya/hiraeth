defmodule HiraethWeb.AdminReviewLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Hiraeth.Accounts.User
  alias Hiraeth.Catalog.Edition
  alias Hiraeth.Imports.{ImportRun, ReviewItem, StagedImportRow}
  alias Hiraeth.Sources.{CurationOverride, SourceRecord}

  test "admin approves and rejects review items and applies a curation override", %{conn: conn} do
    %{
      conn: conn,
      admin: admin,
      review_item: review_item,
      reject_item: reject_item,
      edition: edition,
      source_record: source_record
    } =
      review_context(conn)

    assert {:ok, view, html} = live(conn, ~p"/admin/review")
    assert html =~ "Review queue"
    assert has_element?(view, "#review-item-#{review_item.id}")
    assert has_element?(view, "#review-item-#{reject_item.id}")

    view
    |> element("#approve-review-#{review_item.id}")
    |> render_click()

    assert Ash.reload!(review_item, authorize?: false).decision == "approved"
    refute has_element?(view, "#review-item-#{review_item.id}")

    view
    |> element("#reject-review-#{reject_item.id}")
    |> render_click()

    assert Ash.reload!(reject_item, authorize?: false).decision == "rejected"
    refute has_element?(view, "#review-item-#{reject_item.id}")

    assert {:ok, detail, _html} = live(conn, ~p"/admin/review/#{review_item.id}")
    assert has_element?(detail, "#review-detail-shell")

    detail
    |> form("#curation-override-form", %{
      "curation_override" => %{
        "entity_type" => "edition",
        "entity_id" => edition.id,
        "field_name" => "title",
        "curated_value" => "Curated Orchard Title",
        "reason" => "Manual title normalization",
        "source_record_id" => source_record.id
      }
    })
    |> render_submit()

    override = Ash.read_one!(CurationOverride, authorize?: false)
    assert override.curated_value == "Curated Orchard Title"
    assert override.reviewer_id == admin.id
  end

  test "non-admin visitors are redirected away from admin review", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/review")
  end

  test "authenticated malformed review detail ids redirect without crashing", %{conn: conn} do
    %{conn: conn} = review_context(conn)

    assert {:error, {:live_redirect, %{to: "/admin/review"}}} =
             live(conn, ~p"/admin/review/not-a-uuid")
  end

  defp review_context(conn) do
    Hiraeth.DemoFixtures.seed!()
    admin = seed_admin!("review-admin@example.test", "correct horse battery staple")

    edition =
      Enum.find(
        Ash.read!(Edition, authorize?: false),
        &(&1.slug == "the-orchard-of-minor-moons-paperback")
      )

    source_record =
      Enum.find(
        Ash.read!(SourceRecord, authorize?: false),
        &(&1.source_uri == "local_demo_fixture:edition:the-orchard-of-minor-moons-paperback")
      )

    import_run =
      ImportRun
      |> Ash.Changeset.for_create(:create, %{provider: "local_admin_test", status: "review"})
      |> Ash.create!(actor: admin)

    staged_row =
      StagedImportRow
      |> Ash.Changeset.for_create(:create, %{
        import_run_id: import_run.id,
        row_number: 1,
        raw_payload: %{"title" => "The Orchard"},
        status: "needs_review"
      })
      |> Ash.create!(actor: admin)

    review_item =
      create_review!(
        admin,
        import_run,
        staged_row,
        "Title conflict for The Orchard of Minor Moons"
      )

    reject_item = create_review!(admin, import_run, staged_row, "Duplicate ISBN candidate")

    signed_in = sign_in!(admin, "correct horse battery staple")

    %{
      conn:
        conn
        |> init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(signed_in),
      admin: admin,
      review_item: review_item,
      reject_item: reject_item,
      edition: edition,
      source_record: source_record
    }
  end

  defp create_review!(admin, import_run, staged_row, message) do
    ReviewItem
    |> Ash.Changeset.for_create(:create, %{
      entity_type: "edition",
      decision: "pending",
      message: message,
      import_run_id: import_run.id,
      staged_import_row_id: staged_row.id
    })
    |> Ash.create!(actor: admin)
  end

  defp seed_admin!(email, password) do
    User
    |> Ash.Changeset.for_create(:seed_admin, %{
      email: email,
      password: password,
      display_name: "Review Admin"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in!(user, password) do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: user.email, password: password})
    |> Ash.read_one!()
  end
end
