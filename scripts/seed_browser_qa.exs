# Seeds deterministic records used only by scripts/browser_qa.sh real-browser coverage.
# The data is local, fictional, provenance-safe, and reset by browser_qa.sh before each run.

alias Hiraeth.Accounts.User
alias Hiraeth.Catalog.Edition
alias Hiraeth.Imports.{ImportRun, ReviewItem, StagedImportRow}

if Mix.env() not in [:dev, :test] do
  raise "scripts/seed_browser_qa.exs may only run in dev/test environments"
end

admin_email = System.get_env("HIRAETH_BROWSER_ADMIN_EMAIL", "real-catalog-admin@example.test")
admin_password = System.get_env("HIRAETH_BROWSER_ADMIN_PASSWORD", "correct horse battery staple")

admin =
  User
  |> Ash.read!(authorize?: false)
  |> Enum.find(&(to_string(&1.email) == admin_email)) ||
    User
    |> Ash.Changeset.for_create(:seed_admin, %{
      email: admin_email,
      password: admin_password,
      display_name: "Browser QA Admin"
    })
    |> Ash.create!(authorize?: false)

edition =
  Edition
  |> Ash.read!(authorize?: false)
  |> Enum.find(&(&1.slug == "deep-vellum-immigrant-paperback-9781646054541")) ||
    raise "real catalog edition missing; run priv/repo/seeds.exs first"

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

IO.puts("seeded browser_qa_import review row for #{edition.slug}")
