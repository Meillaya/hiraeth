defmodule Hiraeth.RealCatalogFixtures do
  @moduledoc """
  Deterministic seed entrypoint for the tracked real publisher production corpus.
  """

  alias Hiraeth.RealCatalog.Importer

  def seed! do
    Importer.seed!()
  end
end
