defmodule Hiraeth.RealCatalogFixtures do
  @moduledoc """
  Deterministic seed entrypoint for the tracked real publisher production corpus.
  """

  def seed! do
    Hiraeth.RealCatalog.Importer.seed!()
  end
end
