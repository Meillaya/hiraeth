defmodule Hiraeth.TestSupport.MixTaskMocks.MockCoverPipeline do
  @moduledoc false

  def download_and_cache!(_cover_urls, _provider_config) do
    {:ok, %{}}
  end
end
