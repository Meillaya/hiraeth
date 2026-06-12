defmodule HiraethWeb.AdminCoversLiveTest do
  use HiraethWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Hiraeth.Accounts.User
  alias Hiraeth.Catalog.Edition
  alias Hiraeth.Covers.CoverAssignment

  test "admin assigns and hides a cover, and public edition falls back after takedown", %{
    conn: conn
  } do
    %{conn: conn, edition: edition} = cover_context(conn)

    assert {:ok, view, html} = live(conn, ~p"/admin/covers")
    assert html =~ "Cover governance"

    view
    |> form("#cover-assignment-form", %{
      "cover_assignment" => %{
        "edition_id" => edition.id,
        "source_url" => "https://example.test/covers/orchard-admin.jpg",
        "provider" => "local_admin_test",
        "rights_basis" => "link_permitted",
        "attribution_text" => "Admin test cover"
      }
    })
    |> render_submit()

    assignment =
      CoverAssignment
      |> Ash.read!(authorize?: false)
      |> Ash.load!(:cover_asset)
      |> Enum.find(
        &(&1.cover_asset.source_url == "https://example.test/covers/orchard-admin.jpg")
      )

    assert assignment.visible?
    assert assignment.cover_asset.source_url == "https://example.test/covers/orchard-admin.jpg"

    assert has_element?(
             view,
             ~s|#preview-cover-#{assignment.id}[href="/editions/the-orchard-of-minor-moons-paperback"]|
           )

    assert {:ok, public_before, public_html_before} =
             live(conn, ~p"/editions/the-orchard-of-minor-moons-paperback")

    assert public_html_before =~ "https://example.test/covers/orchard-admin.jpg"
    assert has_element?(public_before, "#cover-attribution", "Admin test cover")

    view
    |> element("#hide-cover-#{assignment.id}")
    |> render_click()

    hidden_assignment = Ash.reload!(assignment, authorize?: false) |> Ash.load!(:cover_asset)
    refute hidden_assignment.visible?
    assert hidden_assignment.cover_asset.takedown_state == "hidden"

    assert has_element?(
             view,
             ~s|#preview-cover-#{assignment.id}[href="/editions/the-orchard-of-minor-moons-paperback"]|
           )

    assert {:ok, public_after, public_html_after} =
             live(conn, ~p"/editions/the-orchard-of-minor-moons-paperback")

    refute public_html_after =~ "https://example.test/covers/orchard-admin.jpg"
    assert has_element?(public_after, "#missing-cover-the-orchard-of-minor-moons-paperback")
  end

  test "non-admin visitors are redirected away from cover governance", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/covers")
  end

  defp cover_context(conn) do
    Hiraeth.DemoFixtures.seed!()
    admin = seed_admin!("cover-admin@example.test", "correct horse battery staple")

    edition =
      Enum.find(
        Ash.read!(Edition, authorize?: false),
        &(&1.slug == "the-orchard-of-minor-moons-paperback")
      )

    signed_in = sign_in!(admin, "correct horse battery staple")

    %{
      conn:
        conn
        |> init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(signed_in),
      edition: edition
    }
  end

  defp seed_admin!(email, password) do
    User
    |> Ash.Changeset.for_create(:seed_admin, %{
      email: email,
      password: password,
      display_name: "Cover Admin"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in!(user, password) do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: user.email, password: password})
    |> Ash.read_one!()
  end
end
