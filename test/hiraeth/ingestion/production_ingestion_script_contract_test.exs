defmodule Hiraeth.Ingestion.ProductionIngestionScriptContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  test "ingestion drills start devenv postgres and wait for readiness before test execution" do
    with_fake_commands(fn bin, log ->
      env = fake_env(bin, ARTIFACT_DIR: temp_dir())

      assert {_, 0} =
               System.cmd("bash", [script("production_ingestion_drill.sh")],
                 env: env,
                 stderr_to_stdout: true
               )

      assert {_, 0} =
               System.cmd("bash", [script("production_ingestion_adversarial.sh")],
                 env: env,
                 stderr_to_stdout: true
               )

      commands = read_commands(log)

      assert ordered?(
               commands,
               "nix run nixpkgs#devenv -- up -d hiraeth-postgres",
               "mix test scripts/qa/ingestion/production_ingestion_drill_test.exs --only provider_replay --seed 0 --trace"
             )

      assert ordered?(
               commands,
               "pg_isready -h localhost -p 54320 -U postgres",
               "mix test scripts/qa/ingestion/production_ingestion_drill_test.exs --only provider_replay --seed 0 --trace"
             )

      assert ordered?(
               commands,
               "nix run nixpkgs#devenv -- up -d hiraeth-postgres",
               "mix test scripts/qa/ingestion/production_ingestion_adversarial_test.exs --only destructive_diff --seed 0 --trace"
             )

      assert ordered?(
               commands,
               "pg_isready -h localhost -p 54320 -U postgres",
               "mix test scripts/qa/ingestion/production_ingestion_adversarial_test.exs --only destructive_diff --seed 0 --trace"
             )

      refute Enum.any?(commands, &String.starts_with?(&1, "docker ")),
             "ingestion drills must not invoke docker; devenv owns local postgres"
    end)
  end

  @tag :readiness_failure
  test "browser QA stops devenv postgres and skips downstream work when readiness fails" do
    with_fake_commands(fn bin, log ->
      env =
        fake_env(bin,
          CHROME_BIN: "/bin/true",
          QA_DIR: temp_dir(),
          HIRAETH_FAKE_PG_ISREADY_FAIL: "1",
          HIRAETH_POSTGRES_READY_ATTEMPTS: "1",
          HIRAETH_POSTGRES_READY_SLEEP: "0"
        )

      assert {output, status} =
               System.cmd("bash", [Path.join(@root, "scripts/browser_qa.sh")],
                 env: env,
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "FAIL postgres did not become ready"

      commands = read_commands(log)

      assert "nix run nixpkgs#devenv -- up -d hiraeth-postgres" in commands
      assert "pg_isready -h localhost -p 54320 -U postgres" in commands
      assert "nix run nixpkgs#devenv -- processes stop hiraeth-postgres" in commands

      refute Enum.any?(commands, &String.starts_with?(&1, "mix "))

      refute Enum.any?(commands, &String.starts_with?(&1, "docker ")),
             "browser QA failure path must not invoke docker; devenv owns local postgres"
    end)
  end

  test "make verify migrated local targets use shared devenv postgres readiness helper" do
    makefile = File.read!(Path.join(@root, "Makefile"))

    refute makefile =~ ~r/\bdocker\b/i,
           "Makefile targets must use devenv-managed postgres, not docker"

    assert makefile =~ "scripts/dev/ensure_postgres.sh start"
  end

  defp with_fake_commands(fun) do
    root = temp_dir()
    bin = Path.join(root, "bin")
    log = Path.join(root, "commands.log")
    File.mkdir_p!(bin)
    File.write!(log, "")
    write_fake_docker!(bin, log)
    write_fake_nix!(bin, log)
    write_fake_pg_isready!(bin, log)
    write_fake_mix!(bin, log)
    write_fake_lsof!(bin, log)
    write_fake_uv!(bin, log)
    fun.(bin, log)
  end

  defp fake_env(bin, overrides) do
    base = [
      {"PATH", "#{bin}:#{System.get_env("PATH")}"},
      {"DATABASE_HOST", "localhost"},
      {"HIRAETH_POSTGRES_READY_ATTEMPTS", "1"},
      {"HIRAETH_POSTGRES_READY_SLEEP", "0"}
    ]

    base ++ Enum.map(overrides, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp write_fake_docker!(bin, log) do
    write_executable!(Path.join(bin, "docker"), """
    #!/usr/bin/env bash
    echo "docker $*" >> #{sh(log)}
    exit 0
    """)
  end

  defp write_fake_nix!(bin, log) do
    write_executable!(Path.join(bin, "nix"), """
    #!/usr/bin/env bash
    echo "nix $*" >> #{sh(log)}
    exit 0
    """)
  end

  defp write_fake_pg_isready!(bin, log) do
    write_executable!(Path.join(bin, "pg_isready"), """
    #!/usr/bin/env bash
    echo "pg_isready $*" >> #{sh(log)}
    if [[ "${HIRAETH_FAKE_PG_ISREADY_FAIL:-}" == "1" ]]; then
      exit 1
    fi
    exit 0
    """)
  end

  defp write_fake_mix!(bin, log) do
    write_executable!(Path.join(bin, "mix"), """
    #!/usr/bin/env bash
    echo "mix $*" >> #{sh(log)}
    exit 0
    """)
  end

  defp write_fake_uv!(bin, log) do
    write_executable!(Path.join(bin, "uv"), """
    #!/usr/bin/env bash
    echo "uv $*" >> #{sh(log)}
    exit 0
    """)
  end

  defp write_fake_lsof!(bin, log) do
    write_executable!(Path.join(bin, "lsof"), """
    #!/usr/bin/env bash
    echo "lsof $*" >> #{sh(log)}
    exit 1
    """)
  end

  defp write_executable!(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp script(name), do: Path.join(@root, "scripts/qa/ingestion/#{name}")

  defp temp_dir do
    Path.join(System.tmp_dir!(), "hiraeth-script-contract-#{System.unique_integer([:positive])}")
  end

  defp read_commands(log) do
    log
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp ordered?(commands, earlier, later) do
    with earlier_index when is_integer(earlier_index) <-
           Enum.find_index(commands, &(&1 == earlier)),
         later_index when is_integer(later_index) <- Enum.find_index(commands, &(&1 == later)) do
      earlier_index < later_index
    else
      _missing -> false
    end
  end

  defp sh(path), do: "'#{String.replace(path, "'", "'\\''")}'"
end
