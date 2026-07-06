defmodule Hiraeth.TestSupport.MixTaskMocks.MockUnhealthySidecarClient do
  def health(_opts \\ []) do
    {:error, "connection refused"}
  end
end
