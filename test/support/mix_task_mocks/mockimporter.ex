defmodule Hiraeth.TestSupport.MixTaskMocks.MockImporter do
  def seed_provider!(_dataset, _import_run) do
    {:ok, %{publishers: 0, editions: 0, source_records: 0}}
  end
end
