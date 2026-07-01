defmodule Hiraeth.TestSupport.MixTaskMocks.MockConfigCaptureSidecarClient do
  def health(_opts \\ []) do
    Hiraeth.TestSupport.MixTaskMocks.MockSidecarClient.health()
  end

  def fetch(provider_config, _opts \\ []) do
    send(Process.get(:capture_pid), {:fetch_provider_config, provider_config})
    Hiraeth.TestSupport.MixTaskMocks.MockSidecarClient.fetch(provider_config)
  end

  def scrape(provider_config, _opts \\ []) do
    send(Process.get(:capture_pid), {:scrape_provider_config, provider_config})
    Hiraeth.TestSupport.MixTaskMocks.MockSidecarClient.scrape(provider_config)
  end

  def detail(source_uri, provider, opts) do
    Hiraeth.TestSupport.MixTaskMocks.MockSidecarClient.detail(source_uri, provider, opts)
  end
end
