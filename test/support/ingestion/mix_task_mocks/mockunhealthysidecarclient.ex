defmodule Hiraeth.TestSupport.MixTaskMocks.MockUnhealthySidecarClient do
  @moduledoc false

  def health(_opts \\ []) do
    {:error, "connection refused"}
  end
end
