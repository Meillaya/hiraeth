defmodule Hiraeth.ImportsResourceTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Imports.ImportRun

  setup do
    %{admin: trusted_catalog_actor()}
  end

  test "import runs are created with provider, status, and row_limit like ingestion phases", %{
    admin: admin
  } do
    run =
      ImportRun
      |> Ash.Changeset.for_create(:create, %{
        provider: "lineage_provider",
        status: "applied",
        row_limit: 3
      })
      |> Ash.create!(actor: admin)

    assert run.provider == "lineage_provider"
    assert run.status == "applied"
    assert run.row_limit == 3

    assert [%ImportRun{id: id}] =
             ImportRun
             |> Ash.read!(authorize?: false)
             |> Enum.filter(&(&1.provider == "lineage_provider"))

    assert id == run.id
  end

  test "import runs default to draft status and a 250 row limit", %{admin: admin} do
    run =
      ImportRun
      |> Ash.Changeset.for_create(:create, %{provider: "default_lineage"})
      |> Ash.create!(actor: admin)

    assert run.status == "draft"
    assert run.row_limit == 250
  end

  test "import run status can be updated by a trusted writer", %{admin: admin} do
    run =
      ImportRun
      |> Ash.Changeset.for_create(:create, %{provider: "status_lineage"})
      |> Ash.create!(actor: admin)

    updated =
      run
      |> Ash.Changeset.for_update(:update, %{status: "applied"})
      |> Ash.update!(actor: admin)

    assert updated.status == "applied"
  end

  test "import run writes require a trusted catalog writer", %{admin: admin} do
    forbidden =
      ImportRun
      |> Ash.Changeset.for_create(:create, %{provider: "blocked"})
      |> Ash.create(actor: nil)

    assert {:error, error} = forbidden
    assert Exception.message(error) =~ "forbidden"

    assert %ImportRun{} =
             ImportRun
             |> Ash.Changeset.for_create(:create, %{provider: "allowed"})
             |> Ash.create!(actor: admin)
  end
end
