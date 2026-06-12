# Seeds deterministic records used only by scripts/browser_qa.sh real-browser coverage.
# The data is local, fictional, provenance-safe, and reset by browser_qa.sh before each run.

alias Hiraeth.Accounts.User
alias Hiraeth.Catalog.Edition
alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
alias Hiraeth.Imports.{ImportRun, ReviewItem, StagedImportRow}

admin =
  User
  |> Ash.read!(authorize?: false)
  |> Enum.find(&(to_string(&1.email) == "demo-fixtures-admin@example.test")) ||
    raise "demo fixture admin missing; run priv/repo/seeds.exs first"

edition =
  Edition
  |> Ash.read!(authorize?: false)
  |> Enum.find(&(&1.slug == "the-orchard-of-minor-moons-paperback")) ||
    raise "demo fixture edition missing; run priv/repo/seeds.exs first"

run =
  ImportRun
  |> Ash.read!(authorize?: false)
  |> Enum.find(&(&1.provider == "browser_qa_import")) ||
    ImportRun
    |> Ash.Changeset.for_create(:create, %{
      provider: "browser_qa_import",
      status: "review",
      row_limit: 250
    })
    |> Ash.create!(actor: admin)

row =
  StagedImportRow
  |> Ash.read!(authorize?: false)
  |> Enum.find(&(&1.import_run_id == run.id and &1.row_number == 1)) ||
    StagedImportRow
    |> Ash.Changeset.for_create(:create, %{
      import_run_id: run.id,
      row_number: 1,
      raw_payload: %{
        "title" => "Browser QA Review Row",
        "isbn" => "",
        "publisher" => "Browser QA Press"
      },
      status: "needs_review"
    })
    |> Ash.create!(actor: admin)

ReviewItem
|> Ash.read!(authorize?: false)
|> Enum.find(
  &(&1.import_run_id == run.id and &1.message == "Browser QA missing ISBN review item")
) ||
  ReviewItem
  |> Ash.Changeset.for_create(:create, %{
    import_run_id: run.id,
    staged_import_row_id: row.id,
    entity_type: "staged_import_row",
    decision: "pending",
    message: "Browser QA missing ISBN review item"
  })
  |> Ash.create!(actor: admin)

cover =
  CoverAsset
  |> Ash.read!(authorize?: false)
  |> Enum.find(&(&1.source_url == "/images/logo.svg" and &1.provider == "browser_qa_local_cover")) ||
    CoverAsset
    |> Ash.Changeset.for_create(:create, %{
      source_url: "/images/logo.svg",
      provider: "browser_qa_local_cover",
      rights_basis: "local_static_asset_fixture",
      attribution_text: "Browser QA cover attribution",
      cache_policy: "link_only",
      takedown_state: "visible"
    })
    |> Ash.create!(actor: admin)

CoverAssignment
|> Ash.read!(authorize?: false)
|> Enum.find(&(&1.edition_id == edition.id and &1.cover_asset_id == cover.id)) ||
  CoverAssignment
  |> Ash.Changeset.for_create(:create, %{
    edition_id: edition.id,
    cover_asset_id: cover.id,
    position: 1,
    visible?: true
  })
  |> Ash.create!(actor: admin)

IO.puts("seeded browser_qa_import review row and browser_qa_local_cover assignment")
