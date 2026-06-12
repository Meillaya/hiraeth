defmodule Hiraeth.RealCatalogFixtures do
  @moduledoc """
  Deterministic seed entrypoint for the tracked real publisher pilot dataset.
  """

  def seed! do
    Hiraeth.RealCatalog.Importer.seed!()
  end
end
