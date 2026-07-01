defmodule Hiraeth.TestSupport.MixTaskMocks.MockCoverPipeline do
  def download_and_cache!(_cover_urls, _provider_config) do
    {:ok, %{}}
  end
end
