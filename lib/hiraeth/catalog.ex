defmodule Hiraeth.Catalog do
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
