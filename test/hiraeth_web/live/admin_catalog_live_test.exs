defmodule HiraethWeb.AdminCatalogLiveTest do
  use HiraethWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hiraeth.Accounts.User
  alias Hiraeth.Catalog.{Contribution, Edition, Identifier, Publisher, Work}
  alias Hiraeth.Covers.CoverAssignment

  test "unauthenticated visitors cannot access admin catalog pages", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/editions")
  end

  test "all admin catalog sections expose protected create/update workspaces", %{conn: conn} do
    %{conn: conn} = signed_in_catalog_context(conn)

    for path <- [
          ~p"/admin/publishers",
          ~p"/admin/imprints",
          ~p"/admin/works",
          ~p"/admin/contributors",
          ~p"/admin/series",
          ~p"/admin/identifiers",
          ~p"/admin/covers",
          ~p"/admin/curation-overrides"
        ] do
      assert {:ok, view, html} = live(conn, path)
      assert html =~ "Protected AshPhoenix create/update workspace"
      assert has_element?(view, "#admin-resource-form")
      assert has_element?(view, "#admin-resource-list")
    end
  end

  test "direct nested edition write is rejected without admin actor", %{conn: conn} do
    %{publisher: publisher, work: work} = signed_in_catalog_context(conn)

    result =
      Edition
      |> Ash.Changeset.for_create(:create_with_catalog_edges, %{
        title: "Forbidden Nested Edition",
        slug: unique_slug("forbidden-edition"),
        publisher_id: publisher.id,
        work_id: work.id,
        contributor: %{"display_name" => "Forbidden Writer"},
        identifier: %{"identifier_type" => "isbn_13", "value" => "978-5-5555-9999-9"}
      })
      |> Ash.create()

    assert {:error, error} = result
    assert Exception.message(error) =~ "forbidden"
  end

  test "admin sees validation errors from the AshPhoenix edition form and nested fields", %{
    conn: conn
  } do
    %{conn: conn, publisher: publisher, work: work} = signed_in_catalog_context(conn)
    assert {:ok, view, _html} = live(conn, ~p"/admin/editions")

    html =
      view
      |> form("#edition-form", %{
        "edition" => %{
          "title" => "",
          "slug" => "",
          "publisher_id" => publisher.id,
          "work_id" => work.id,
          "contributor" => %{"display_name" => "", "role" => "author"},
          "identifier" => %{"identifier_type" => "isbn_13", "value" => ""}
        }
      })
      |> render_submit()

    assert html =~ "Edition could not be saved"
    assert html =~ "Title can&#39;t be blank" or html =~ "Title can’t be blank"

    assert html =~ "Contributor name can&#39;t be blank" or
             html =~ "Contributor name can’t be blank"

    assert html =~ "Identifier value can&#39;t be blank" or
             html =~ "Identifier value can’t be blank"
  end

  test "admin creates an edition with nested contributor and ISBN", %{conn: conn} do
    %{conn: conn, publisher: publisher, work: work} = signed_in_catalog_context(conn)
    assert {:ok, view, _html} = live(conn, ~p"/admin/editions")

    html =
      view
      |> form("#edition-form", %{
        "edition" => %{
          "title" => "The Nested Form Book",
          "subtitle" => "Catalogued in LiveView",
          "slug" => unique_slug("edition"),
          "publisher_id" => publisher.id,
          "work_id" => work.id,
          "format" => "paperback",
          "contributor" => %{
            "display_name" => "Avery Nested",
            "sort_name" => "Nested, Avery",
            "slug" => unique_slug("contributor"),
            "role" => "author"
          },
          "identifier" => %{"identifier_type" => "isbn_13", "value" => "978-5-5555-5555-5"},
          "cover" => %{
            "provider" => "local_test",
            "source_url" => "https://example.test/covers/nested-form-book.jpg",
            "rights_basis" => "link_permitted",
            "attribution_text" => "Local test cover source"
          }
        }
      })
      |> render_submit()

    assert html =~ "Edition created"
    assert html =~ "The Nested Form Book"
    assert html =~ "Avery Nested"
    assert html =~ "978-5-5555-5555-5"

    created_slug = extract_created_slug(html)

    edition =
      Edition
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.slug == created_slug))

    assert edition.title == "The Nested Form Book"

    identifier =
      Identifier
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.edition_id == edition.id and &1.value == "978-5-5555-5555-5"))

    assert identifier.identifier_type == "isbn_13"

    contribution =
      Contribution
      |> Ash.Query.load(:contributor)
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.edition_id == edition.id and &1.role == "author"))

    assert contribution.contributor.display_name == "Avery Nested"

    assignment =
      CoverAssignment
      |> Ash.Query.load(:cover_asset)
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.edition_id == edition.id))

    assert assignment.cover_asset.provider == "local_test"
    assert assignment.cover_asset.cache_policy == "link_only"
    assert assignment.cover_asset.attribution_text == "Local test cover source"
  end

  test "admin updates an existing edition through AshPhoenix for_update", %{conn: conn} do
    %{conn: conn, admin: admin, publisher: publisher, work: work} =
      signed_in_catalog_context(conn)

    edition =
      create!(
        Edition,
        %{
          title: "000 Editable Edition",
          slug: unique_slug("editable-edition"),
          publisher_id: publisher.id,
          work_id: work.id
        },
        admin
      )

    assert {:ok, view, _html} = live(conn, ~p"/admin/editions")

    assert view |> element("#edition-#{edition.id} button", "Edit") |> render_click() =~
             "Update edition"

    html =
      view
      |> form("#edition-form", %{
        "edition" => %{
          "title" => "Updated Edition",
          "slug" => edition.slug,
          "publisher_id" => publisher.id,
          "work_id" => work.id,
          "format" => "hardcover"
        }
      })
      |> render_submit()

    assert html =~ "Edition updated"
    assert Ash.get!(Edition, edition.id, authorize?: false).title == "Updated Edition"
  end

  defp signed_in_catalog_context(conn) do
    admin = seed_admin!("catalog-live-#{System.unique_integer([:positive])}@example.test")

    publisher =
      create!(Publisher, %{name: "Admin Catalog Press", slug: unique_slug("publisher")}, admin)

    work = create!(Work, %{title: "Admin Catalog Work", slug: unique_slug("work")}, admin)

    signed_in = sign_in!(admin, "correct horse battery staple")

    conn =
      conn
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(signed_in)

    %{conn: conn, admin: admin, publisher: publisher, work: work}
  end

  defp seed_admin!(email) do
    User
    |> Ash.Changeset.for_create(:seed_admin, %{
      email: email,
      password: "correct horse battery staple",
      display_name: "Catalog Live Admin"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in!(user, password) do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: user.email, password: password})
    |> Ash.read_one!()
  end

  defp create!(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: actor)
  end

  defp extract_created_slug(html) do
    [[slug]] = Regex.scan(~r/data-created-edition-slug="([^"]+)"/, html, capture: :all_but_first)
    slug
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
