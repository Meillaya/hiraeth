defmodule Hiraeth.TestSupport.MixTaskMocks.MockConfigCaptureSidecarClient do
  @moduledoc false

  alias Hiraeth.TestSupport.MixTaskMocks.MockSidecarClient

  def health(_opts \\ []) do
    MockSidecarClient.health()
  end

  def fetch(provider_config, _opts \\ []) do
    send(Process.get(:capture_pid), {:fetch_provider_config, provider_config})
    MockSidecarClient.fetch(provider_config)
  end

  def scrape(provider_config, _opts \\ []) do
    send(Process.get(:capture_pid), {:scrape_provider_config, provider_config})
    MockSidecarClient.scrape(provider_config)
  end

  def detail(source_uri, provider, opts) do
    MockSidecarClient.detail(source_uri, provider, opts)
  end
end
