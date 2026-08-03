defmodule Hiraeth.Imports do
  @moduledoc "Ash domain: CSV/manual import staging, mappings, runs, and review items."

  use Ash.Domain

  resources do
    resource Hiraeth.Imports.ImportRun
    resource Hiraeth.Imports.ImportMapping
    resource Hiraeth.Imports.StagedImportRow
    resource Hiraeth.Imports.ReviewItem
  end
end
