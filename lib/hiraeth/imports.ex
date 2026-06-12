defmodule Hiraeth.Imports do
  use Ash.Domain

  resources do
    resource Hiraeth.Imports.ImportRun
    resource Hiraeth.Imports.ImportMapping
    resource Hiraeth.Imports.StagedImportRow
    resource Hiraeth.Imports.ReviewItem
  end
end
