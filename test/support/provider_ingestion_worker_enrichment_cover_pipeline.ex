defmodule Hiraeth.TestSupport.ProviderIngestionWorkerEnrichmentCoverPipeline do
  @moduledoc false

  def download_and_cache!(_cover_urls, _provider_config), do: {:ok, %{}}
end
