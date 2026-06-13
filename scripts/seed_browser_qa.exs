# Seeds deterministic records used only by scripts/browser_qa.sh real-browser coverage.
# The data is local, fictional, provenance-safe, and reset by browser_qa.sh before each run.

alias Hiraeth.Accounts.User
alias Hiraeth.Catalog.Edition
alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
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

cache_path = "priv/static/covers/cache/browser-qa-immigrant.png"
thumbnail_path = "priv/static/covers/cache/browser-qa-immigrant-thumb.png"
File.mkdir_p!(Path.dirname(cache_path))

File.write!(
  cache_path,
  Base.decode64!(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
  )
)

File.write!(
  thumbnail_path,
  Base.decode64!(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
  )
)

cached_cover =
  CoverAsset
  |> Ash.read!(authorize?: false)
  |> Enum.find(&(&1.source_url == "https://covers.example.test/browser-qa-immigrant.png")) ||
    CoverAsset
    |> Ash.Changeset.for_create(:create, %{
      source_url: "https://covers.example.test/browser-qa-immigrant.png",
      provider: "fixture-covers",
      rights_basis: "local_cache_permitted",
      attribution_text: "Browser QA cached cover",
      cache_policy: "cache_allowed",
      cached_file_path: cache_path,
      thumbnail_file_path: thumbnail_path,
      cached_at: DateTime.utc_now(:second),
      takedown_state: "visible"
    })
    |> Ash.create!(authorize?: false)

cached_cover =
  if cached_cover.cached_file_path == cache_path and
       cached_cover.thumbnail_file_path == thumbnail_path do
    cached_cover
  else
    cached_cover
    |> Ash.Changeset.for_update(:update, %{
      cache_policy: "cache_allowed",
      cached_file_path: cache_path,
      thumbnail_file_path: thumbnail_path,
      cached_at: DateTime.utc_now(:second)
    })
    |> Ash.update!(authorize?: false)
  end

cached_assignment =
  CoverAssignment
  |> Ash.read!(authorize?: false)
  |> Enum.find(&(&1.edition_id == edition.id and &1.cover_asset_id == cached_cover.id)) ||
    CoverAssignment
    |> Ash.Changeset.for_create(:create, %{
      edition_id: edition.id,
      cover_asset_id: cached_cover.id,
      position: -1,
      visible?: true
    })
    |> Ash.create!(authorize?: false)

CoverAssignment
|> Ash.read!(authorize?: false)
|> Enum.filter(&(&1.edition_id == edition.id and &1.id != cached_assignment.id and &1.visible?))
|> Enum.each(fn assignment ->
  assignment
  |> Ash.Changeset.for_update(:update, %{visible?: false})
  |> Ash.update!(authorize?: false)
end)

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

IO.puts("seeded browser_qa_import review row and cached cover for #{edition.slug}")
