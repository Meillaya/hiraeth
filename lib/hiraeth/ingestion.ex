defmodule Hiraeth.Ingestion do
  @moduledoc "Ash domain: provider sources, runs, snapshots, candidates, and ingestion events."

  use Ash.Domain

  resources do
    resource Hiraeth.Ingestion.ProviderSource
    resource Hiraeth.Ingestion.ProviderRun
    resource Hiraeth.Ingestion.SourceSnapshot
    resource Hiraeth.Ingestion.RecordCandidate
    resource Hiraeth.Ingestion.IngestionEvent
  end
end
