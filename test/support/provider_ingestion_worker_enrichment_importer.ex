defmodule Hiraeth.TestSupport.ProviderIngestionWorkerEnrichmentImporter do
  @moduledoc false

  def seed_provider!(dataset, _import_run) do
    send(
      Application.fetch_env!(:hiraeth, :provider_ingestion_worker_enrichment_test_pid),
      {:import_dataset, dataset}
    )

    {:ok,
     %{
       publishers: 1,
       editions: length(dataset.records),
       source_records: length(dataset.records)
     }}
  end
end
