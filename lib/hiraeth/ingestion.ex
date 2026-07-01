defmodule Hiraeth.Ingestion do
  use Ash.Domain

  resources do
    resource Hiraeth.Ingestion.ProviderSource
    resource Hiraeth.Ingestion.ProviderRun
    resource Hiraeth.Ingestion.SourceSnapshot
    resource Hiraeth.Ingestion.RecordCandidate
    resource Hiraeth.Ingestion.IngestionEvent
  end
end
