defmodule Hiraeth.Imports do
  @moduledoc "Ash domain: import run lineage rows written by ingestion apply/tombstone phases."

  use Ash.Domain

  resources do
    resource Hiraeth.Imports.ImportRun
  end
end
