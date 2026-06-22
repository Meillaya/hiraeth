defmodule Hiraeth.TestSupport.ProviderIngestionWorkerEnrichmentSidecar do
  @moduledoc false

  alias Hiraeth.TestSupport.ProviderIngestionWorkerEnrichmentRecords, as: Records

  def scrape(provider_config, _opts \\ []) do
    send(test_pid(), {:scrape_config, provider_config})
    {:error, "sidecar scrape failed with status 500"}
  end

  def fetch(provider_config, _opts \\ []) do
    send(test_pid(), {:fetch_config, provider_config})

    {:ok,
     %{
       records: [
         record_for(Application.fetch_env!(:hiraeth, :provider_ingestion_worker_scenario))
       ]
     }}
  end

  def detail(source_uri, vendor, opts \\ []) do
    send(test_pid(), {:detail_called, source_uri, vendor, opts})

    case Application.fetch_env!(:hiraeth, :provider_ingestion_worker_scenario) do
      :enrichment ->
        {:ok,
         %{
           "contributors" => [%{"name" => "Enriched Author", "role" => "author"}],
           "cover" => %{"source_url" => "https://images.testscraper.com/covers/enriched.jpg"},
           "isbn_13" => "9781646050185",
           "published_on" => "2030-01-01",
           "description" => "detail description must not replace present description"
         }}

      :timeout ->
        {:error, "timeout"}

      :malformed ->
        {:error, "detail should not be called for malformed source_uri"}

      :complete ->
        raise "detail should not be called for a complete API fallback record"
    end
  end

  defp record_for(:enrichment), do: Records.incomplete_api_record()
  defp record_for(:complete), do: Records.complete_api_record()
  defp record_for(:timeout), do: Records.record_missing_contributors()
  defp record_for(:malformed), do: Records.record_with_non_binary_source_uri()

  defp test_pid do
    Application.fetch_env!(:hiraeth, :provider_ingestion_worker_enrichment_test_pid)
  end
end
