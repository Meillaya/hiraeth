defmodule Hiraeth.Catalog do
  @moduledoc "Ash domain: work / edition / publisher / contributor / series public catalog graph."

  use Ash.Domain

  resources do
    resource Hiraeth.Catalog.Publisher
    resource Hiraeth.Catalog.Imprint
    resource Hiraeth.Catalog.Work
    resource Hiraeth.Catalog.Edition
    resource Hiraeth.Catalog.Contributor
    resource Hiraeth.Catalog.Contribution
    resource Hiraeth.Catalog.Identifier
    resource Hiraeth.Catalog.Series
    resource Hiraeth.Catalog.SeriesMembership
  end
end
