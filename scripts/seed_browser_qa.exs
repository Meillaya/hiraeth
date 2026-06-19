# Seeds deterministic records used only by scripts/browser_qa.sh real-browser coverage.
# The data is local, fictional, provenance-safe, and reset by browser_qa.sh before each run.

alias Hiraeth.Catalog.{Edition, Series, SeriesMembership}
alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
alias Hiraeth.Imports.{ImportRun, ReviewItem, StagedImportRow}

if Mix.env() not in [:dev, :test] do
  raise "scripts/seed_browser_qa.exs may only run in dev/test environments"
end

catalog_writer = %{id: Ash.UUID.generate(), catalog_write?: true}

edition =
  Edition
  |> Ash.read!(authorize?: false)
  |> Enum.find(&(&1.slug == "deep-vellum-immigrant-paperback-9781646054541")) ||
    raise "real catalog edition missing; run priv/repo/seeds.exs first"

series =
  Series
  |> Ash.read!(authorize?: false)
  |> Enum.find(&(&1.slug == "browser-qa-series")) ||
    Series
    |> Ash.Changeset.for_create(:create, %{
      title: "Browser QA Series",
      slug: "browser-qa-series",
      publisher_id: edition.publisher_id
    })
    |> Ash.create!(actor: catalog_writer)

SeriesMembership
|> Ash.read!(authorize?: false)
|> Enum.find(&(&1.series_id == series.id and &1.work_id == edition.work_id)) ||
  SeriesMembership
  |> Ash.Changeset.for_create(:create, %{
    series_id: series.id,
    work_id: edition.work_id,
    position: 1,
    label: "1"
  })
  |> Ash.create!(actor: catalog_writer)

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
    |> Ash.create!(actor: catalog_writer)

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
    |> Ash.create!(actor: catalog_writer)

cache_path = "priv/static/covers/cache/browser-qa-immigrant.png"
thumbnail_path = "priv/static/covers/cache/browser-qa-immigrant-thumb.png"
File.mkdir_p!(Path.dirname(cache_path))

magick = System.find_executable("magick")

if is_nil(magick) do
  raise "ImageMagick `magick` is required to generate deterministic browser QA cover art"
end

cover_svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="400" height="600" viewBox="0 0 400 600">
  <rect width="400" height="600" fill="#F4EFE6"/>
  <rect x="28" y="28" width="344" height="544" fill="none" stroke="#A33417" stroke-width="3"/>
  <text x="200" y="96" text-anchor="middle" font-family="serif" font-size="19" letter-spacing="5" fill="#A33417">DEEP VELLUM</text>
  <text x="200" y="288" text-anchor="middle" font-family="serif" font-size="56" fill="#1B1714">Immigrant</text>
  <text x="200" y="344" text-anchor="middle" font-family="serif" font-size="23" fill="#7A7165">Joaquín Zihuatanejo</text>
  <text x="200" y="492" text-anchor="middle" font-family="monospace" font-size="14" letter-spacing="3" fill="#A39A8C">BROWSER QA COVER</text>
</svg>
"""

cover_svg_path = Path.join(Path.dirname(cache_path), "browser-qa-immigrant.svg")
File.write!(cover_svg_path, cover_svg)
{_, 0} = System.cmd(magick, [cover_svg_path, cache_path], stderr_to_stdout: true)
{_, 0} = System.cmd(magick, [cache_path, "-thumbnail", "400x600>", thumbnail_path], stderr_to_stdout: true)
File.rm(cover_svg_path)

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
  |> Ash.create!(actor: catalog_writer)

IO.puts("seeded browser_qa_import review row and cached cover for #{edition.slug}")
