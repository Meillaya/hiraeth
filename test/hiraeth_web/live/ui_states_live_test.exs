defmodule HiraethWeb.UiStatesLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Hiraeth.Accounts.User
  alias Hiraeth.Catalog.{Edition, Publisher, Series, SeriesMembership, Work}
  alias Hiraeth.Repo
  alias Hiraeth.Sources.SourceRecord
  alias Hiraeth.Imports.{ImportMapping, ImportRun, ReviewItem, StagedImportRow}
  alias HiraethWeb.CatalogComponents

  @password "correct horse battery staple"

  test "reusable state components render loading, auth-required, and generic errors" do
    assert render_component(&CatalogComponents.loading_skeleton/1,
             id: "state-loading",
             label: "Loading catalog cards"
           ) =~ "Loading catalog cards"

    assert render_component(&CatalogComponents.auth_required_state/1,
             id: "admin-auth-required",
             return_to: "/admin/imports"
           ) =~ "Sign in to continue cataloging"

    assert render_component(&CatalogComponents.error_block/1,
             id: "state-error",
             title: "Could not read shelf",
             message: "The archive kept your filters intact."
           ) =~ "The archive kept your filters intact."
  end

  test "empty catalog and query states preserve the user's filter context", %{conn: conn} do
    {:ok, browse, _html} = live(conn, ~p"/browse?q=ghost&page=99")
    assert has_element?(browse, "#browse-empty", "No catalog entries match")
    assert has_element?(browse, "#browse-empty", "ghost")
    assert has_element?(browse, "#volume-reader-empty", "Adjust or clear the current search")
  end

  test "not-found and missing-cover states are explicit", %{conn: conn} do
    Hiraeth.DemoFixtures.seed!()

    {:ok, publisher, _html} = live(conn, ~p"/publishers/not-a-publisher")
    assert has_element?(publisher, "#publisher-not-found", "No publisher matches")
    assert has_element?(publisher, "a[href='/publishers']", "Back to publishers")

    {:ok, edition, _html} = live(conn, ~p"/editions/the-orchard-of-minor-moons-paperback")
    assert has_element?(edition, "#missing-cover-note", "No sourced cover asset")
    assert has_element?(edition, "#missing-cover-the-orchard-of-minor-moons-paperback")

    {:ok, missing, _html} = live(conn, ~p"/editions/not-an-edition")
    assert has_element?(missing, "#edition-not-found", "No edition matches")
    assert has_element?(missing, "a[href='/browse']", "Back to browse")
  end

  test "publisher with no editions and series with unknown order explain their state", %{
    conn: conn
  } do
    admin = admin!()

    publisher =
      create!(Publisher, %{name: "Empty Shelf Press", slug: "empty-shelf-press"}, admin)

    {:ok, publisher_view, _html} = live(conn, ~p"/publishers/#{publisher.slug}")
    assert has_element?(publisher_view, "#publisher-no-editions", "No editions are attached")

    series = create!(Series, %{title: "Unnumbered Sequence", slug: "unnumbered-sequence"}, admin)
    work = create!(Work, %{title: "Loose Leaf Noon", slug: "loose-leaf-noon"}, admin)

    edition =
      create!(
        Edition,
        %{
          title: "Loose Leaf Noon",
          slug: "loose-leaf-noon-paperback",
          format: "paperback",
          work_id: work.id,
          publisher_id: publisher.id
        },
        admin
      )

    create!(SeriesMembership, %{series_id: series.id, work_id: work.id, position: nil}, admin)

    create!(
      SourceRecord,
      %{
        provider: "local_demo_fixture",
        source_type: "fixture",
        source_uri: "local_demo_fixture:edition:#{edition.slug}",
        license_note: "Local test fixture.",
        raw_payload: %{"title" => "Loose Leaf Noon"},
        imported_at: DateTime.utc_now(:second)
      },
      admin
    )

    {:ok, series_view, _html} = live(conn, ~p"/series/#{series.slug}")
    assert has_element?(series_view, "#series-unknown-order", "Sequence order is not sourced")
    assert has_element?(series_view, "#series-editions", "Loose Leaf Noon")
  end

  test "admin no-imports and parse-error states are visible and preserve provider input", %{
    conn: conn
  } do
    clear_imports!()
    %{conn: conn, admin: admin} = signed_in_admin(conn)

    {:ok, imports, _html} = live(conn, ~p"/admin/imports")
    assert has_element?(imports, "#imports-empty", "No import runs yet")
    assert has_element?(imports, "a[href='/admin/imports/new']", "Start a CSV import")

    {:ok, upload_view, _html} = live(conn, ~p"/admin/imports/new")

    upload =
      file_input(upload_view, "#import-upload-form", :csv, [
        %{
          name: "malformed.csv",
          content: "title,isbn\n\"Unclosed,9787100000020\n",
          type: "text/csv"
        }
      ])

    assert render_upload(upload, "malformed.csv") =~ "malformed.csv"

    html =
      upload_view
      |> form("#import-upload-form", %{
        "import_upload" => %{"provider" => "bad_provider_#{admin.id}"}
      })
      |> render_submit()

    assert html =~ "id=\"import-parse-error\""
    assert html =~ "The CSV could not be parsed"
    assert html =~ "bad_provider_#{admin.id}"
  end

  defp signed_in_admin(conn) do
    admin = admin!()

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

  defp clear_imports! do
    ImportRun
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn run ->
      run_id = Ecto.UUID.dump!(run.id)

      Repo.query!(
        """
        DELETE FROM source_ledger_entries
        WHERE source_record_id IN (
          SELECT id FROM source_records WHERE import_run_id = $1
        )
        """,
        [run_id]
      )

      Repo.query!("DELETE FROM source_records WHERE import_run_id = $1", [run_id])
    end)

    [ReviewItem, ImportMapping, StagedImportRow, ImportRun]
    |> Enum.each(fn resource ->
      resource
      |> Ash.read!(authorize?: false)
      |> Enum.each(&Ash.destroy!(&1, authorize?: false))
    end)
  end

  defp admin! do
    User
    |> Ash.Changeset.for_create(:seed_admin, %{
      email: "ui-states-#{System.unique_integer([:positive])}@example.test",
      password: @password,
      display_name: "UI States Admin"
    })
    |> Ash.create!(authorize?: false)
  end

  defp create!(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: actor)
  end
end
