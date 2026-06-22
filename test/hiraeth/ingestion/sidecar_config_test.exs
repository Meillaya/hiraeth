defmodule Hiraeth.Ingestion.SidecarConfigTest do
  use ExUnit.Case, async: true

  test "scrapling sidecar configuration is loaded" do
    config = Application.get_env(:hiraeth, :scrapling_sidecar)
    assert is_list(config)
    assert config[:base_url] == "http://localhost:8000"
  end
end
