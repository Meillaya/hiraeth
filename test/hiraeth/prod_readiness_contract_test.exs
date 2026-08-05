defmodule Hiraeth.ProdReadinessContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  @tag :ci_devenv_contract
  test "prod config requires sidecar readiness and excludes /health from force_ssl" do
    config = Config.Reader.read!(Path.join(@repo_root, "config/prod.exs"), env: :prod)

    readiness = config[:hiraeth][:readiness]

    assert readiness[:require_sidecar] == true,
           "prod.exs must set config :hiraeth, :readiness, require_sidecar: true"

    force_ssl = config[:hiraeth][HiraethWeb.Endpoint][:force_ssl]
    exclude = force_ssl[:exclude]

    assert exclude[:paths] == ["/health"],
           "prod.exs force_ssl.exclude must include paths: [\"/health\"]"

    assert exclude[:hosts] == ["localhost", "127.0.0.1"],
           "prod.exs force_ssl.exclude must keep the localhost/127.0.0.1 host exclusion"
  end
end
