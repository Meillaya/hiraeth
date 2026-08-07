defmodule Hiraeth.DevEnvironmentContractTest do
  use ExUnit.Case, async: true

  # devenv.nix is preserved-but-dormant per the 2026-08-07 scope change (local dev = nix-profile toolchain + standalone postgres); these pins lock the dormant config as-is.

  @repo_root Path.expand("../..", __DIR__)
  @expected_devenv_lock_policy :flake_and_devenv_locks

  test "Nix flake and devenv contract files are present and pinned" do
    assert_contract_file("flake.nix", "Nix flake contract")
    assert_contract_file("flake.lock", "Nix flake lock")
    assert_contract_file("devenv.nix", "devenv module")
    assert_contract_file("devenv.yaml", "devenv inputs manifest")
    assert_contract_file(".envrc", "direnv entrypoint")
    assert_contract_file("test/hiraeth/dev_environment_contract_test.exs", "devenv contract test")

    flake_nix = read!("flake.nix")
    flake_lock = read!("flake.lock")
    devenv_nix = read!("devenv.nix")
    devenv_yaml = read!("devenv.yaml")
    envrc = read!(".envrc")

    assert flake_lock =~ ~s("nodes"), "flake.lock must be a nonempty Nix lock file"
    assert flake_nix =~ ~s(nixpkgs.url), "flake.nix must pin nixpkgs input"
    assert flake_nix =~ ~s(devenv.url), "flake.nix must pin devenv input"
    assert flake_nix =~ ~s(devenv.lib.mkShell), "flake.nix must build the shell with devenv"
    assert flake_nix =~ ~s(./devenv.nix), "flake.nix must load devenv.nix as the shell module"

    assert devenv_nix =~ ~s(HIRAETH_DEVENV_BEAM_TARGET = "elixir-1.18-otp-27"),
           "devenv.nix must document the CI-compatible BEAM target"

    assert devenv_nix =~ ~s(HIRAETH_DEVENV_REQUIRED_COMMANDS),
           "devenv.nix must declare the command contract that dynamic shell probes verify"

    assert devenv_nix =~ ~s(MIX_BUILD_ROOT = ".devenv/mix-build"),
           "devenv.nix must isolate Mix build output from host _build artifacts"

    assert devenv_nix =~ ~s(DATABASE_HOST),
           "devenv.nix must declare database environment defaults"

    assert devenv_nix =~ ~s(DATABASE_PORT),
           "devenv.nix must declare the current local database port"

    assert devenv_yaml =~ ~s(inputs:), "devenv.yaml must declare devenv inputs"
    assert devenv_yaml =~ ~s(nixpkgs:), "devenv.yaml must keep nixpkgs visible to devenv tooling"
    assert envrc =~ ~s(use flake), ".envrc must load the flake for direnv"
  end

  test "devenv lock policy is explicit" do
    assert_contract_file("flake.lock", "Nix flake lock")

    case @expected_devenv_lock_policy do
      :flake_and_devenv_locks ->
        assert_contract_file("devenv.lock", "devenv lock")

      :flake_lock_only ->
        refute File.exists?(path("devenv.lock")),
               "flake-only lock policy forbids generated or untracked devenv.lock; commit it and use :flake_and_devenv_locks if supported devenv commands create it"
    end
  end

  test "devenv PostgreSQL process matches Phoenix dev and test database defaults" do
    assert_contract_file("devenv.nix", "devenv module")

    devenv_nix = read!("devenv.nix")
    dev_database = database_defaults!("config/dev.exs")
    test_database = database_defaults!("config/test.exs")

    assert dev_database.username == "postgres"
    assert dev_database.password == "postgres"
    assert dev_database.hostname in ["localhost", "127.0.0.1"]
    assert dev_database.port == 54_320

    assert test_database.username == dev_database.username
    assert test_database.password == dev_database.password
    assert test_database.hostname in ["localhost", "127.0.0.1"]
    assert test_database.port == dev_database.port

    assert devenv_nix =~ ~r/services\.postgres\s*=\s*\{/,
           "devenv.nix must configure the managed PostgreSQL service, not only PostgreSQL client packages"

    assert devenv_nix =~ ~r/listen_addresses\s*=\s*"127\.0\.0\.1"/,
           "devenv PostgreSQL service must bind loopback explicitly"

    assert devenv_nix =~ ~r/port\s*=\s*#{dev_database.port};?/,
           "devenv PostgreSQL port must match config/dev.exs and config/test.exs"

    assert devenv_nix =~
             ~r/initialDatabases\s*=\s*\[[\s\S]*name\s*=\s*"#{dev_database.database}";[\s\S]*\]/,
           "devenv PostgreSQL service must create the configured development database"

    assert devenv_nix =~ ~r/initialDatabases\s*=\s*\[[\s\S]*name\s*=\s*"hiraeth_test";[\s\S]*\]/,
           "devenv PostgreSQL service must create the unpartitioned test database used by MIX_ENV=test"

    assert devenv_nix =~
             ~r/initdbArgs\s*=\s*\[[^\]]*--username=postgres/,
           "devenv PostgreSQL service must create the postgres superuser at initdb so the PGUSER=postgres init phase can connect"

    assert devenv_nix =~
             ~r/ALTER ROLE #{dev_database.username} WITH LOGIN SUPERUSER PASSWORD '#{dev_database.password}';/,
           "devenv PostgreSQL service must set the configured database user password"

    assert devenv_nix =~ ~r/DATABASE_HOST\s*=\s*"#{dev_database.hostname}";/
    assert devenv_nix =~ ~r/DATABASE_PORT\s*=\s*"#{dev_database.port}";/
    assert devenv_nix =~ ~r/DATABASE_USER\s*=\s*"#{dev_database.username}";/
    assert devenv_nix =~ ~r/DATABASE_PASSWORD\s*=\s*"#{dev_database.password}";/
    assert devenv_nix =~ ~r/DATABASE_NAME\s*=\s*"#{dev_database.database}";/
    assert devenv_nix =~ ~r/PGUSER\s*=\s*"#{dev_database.username}";/
    assert devenv_nix =~ ~r/PGPASSWORD\s*=\s*"#{dev_database.password}";/
  end

  test "devenv declares managed Phoenix process and readiness task" do
    assert_contract_file("devenv.nix", "devenv module")

    devenv_nix = read!("devenv.nix")

    assert devenv_nix =~ ~r/processes\.phoenix\s*=\s*\{/,
           "devenv.nix must declare a managed Phoenix process for devenv up"

    assert devenv_nix =~ ~r/mix\s+phx\.server/,
           "managed Phoenix process must run the existing Phoenix endpoint with mix phx.server"

    assert devenv_nix =~ ~r/services\.postgres\s*=\s*\{/,
           "devenv.nix must declare the managed PostgreSQL service used by Phoenix readiness (socket-only port allocation was fixed upstream by commit 43b5089, PR #3004, in devenv v2.2.1, pin 8f297eae)"

    assert devenv_nix =~ ~r/pg_isready\s+-h\s+127\.0\.0\.1\s+-p\s*54320\s+-U\s*postgres/,
           "managed Phoenix process must coordinate with the devenv PostgreSQL service before migrations/server start"

    assert devenv_nix =~ ~r/ready\s*=\s*\{[\s\S]*http\.get\s*=\s*\{[\s\S]*port\s*=\s*4000;/,
           "managed Phoenix process must expose an HTTP readiness probe on port 4000"

    assert devenv_nix =~ ~r/tasks\."test:phoenix-ready"\s*=\s*\{/,
           "devenv 2.1.2 does not support positional devenv test names, so devenv.nix must declare an executable test:phoenix-ready task wired into devenv test"

    assert devenv_nix =~
             ~r/after\s*=\s*\[[\s\S]*"devenv:processes:postgres"[\s\S]*"devenv:processes:phoenix"[\s\S]*\]/,
           "phoenix-ready task must start PostgreSQL and Phoenix as sibling roots while Phoenix performs its own bounded pg_isready coordination"

    assert devenv_nix =~ ~r/before\s*=\s*\[\s*"devenv:enterTest"\s*\]/,
           "phoenix-ready task must be part of the supported devenv test graph"

    assert devenv_nix =~ ~r/http:\/\/127\.0\.0\.1:4000\//,
           "phoenix-ready task must probe the loopback Phoenix endpoint"

    assert devenv_nix =~ ~r/curl[\s\S]*127\.0\.0\.1:4000\//,
           "phoenix-ready task must use an HTTP probe that fails on non-ready responses"
  end

  test "devenv declares private Scrapling sidecar browser runtime and readiness test" do
    assert_contract_file("devenv.nix", "devenv module")

    devenv_nix = read!("devenv.nix")

    assert devenv_nix =~ ~s(HIRAETH_SIDECAR_BROWSER_EXECUTABLE),
           "devenv.nix must expose the Nix Chromium executable used by Scrapling browser fetchers"

    assert devenv_nix =~ ~s(PLAYWRIGHT_BROWSERS_PATH),
           "devenv.nix must point Patchright/Playwright at a deterministic browser registry"

    assert devenv_nix =~ ~s(PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1"),
           "devenv shell must not require patchright/playwright browser downloads"

    assert devenv_nix =~ ~s(hiraeth-scrapling-browsers),
           "devenv.nix must build a local browser registry compatible with Scrapling's Patchright revision"

    assert devenv_nix =~ ~s(chromium-1223/chrome-linux64/chrome),
           "Patchright's expected Chromium executable path must resolve inside the browser registry"

    assert devenv_nix =~ ~r/processes\."scrapling-sidecar"\s*=\s*\{/,
           "devenv.nix must declare a managed Scrapling sidecar process"

    assert devenv_nix =~ ~r/uv\s+run\s+--extra\s+dev\s+uvicorn\s+app\.main:app/,
           "sidecar process must start the existing FastAPI app through uvicorn"

    assert devenv_nix =~ ~r/--host\s+127\.0\.0\.1/,
           "sidecar process must bind loopback only"

    refute devenv_nix =~ ~r/uvicorn[\s\S]*--host\s+0\.0\.0\.0/,
           "devenv sidecar process must not bind publicly"

    assert devenv_nix =~
             ~r/ready\s*=\s*\{[\s\S]*http\.get\s*=\s*\{[\s\S]*port\s*=\s*8000;[\s\S]*path\s*=\s*"\/health\/";/,
           "sidecar process must expose a loopback /health/ readiness probe"

    assert devenv_nix =~ ~r/tasks\."test:sidecar-ready"\s*=\s*\{/,
           "devenv.nix must declare a sidecar-ready task wired into supported devenv test execution"

    assert devenv_nix =~
             ~r/after\s*=\s*\[[\s\S]*"devenv:processes:scrapling-sidecar"[\s\S]*\]/,
           "sidecar-ready task must start the private Scrapling sidecar process"

    assert devenv_nix =~ ~s(StealthyFetcher) and devenv_nix =~ ~s(DynamicFetcher),
           "sidecar-ready task must prove both Scrapling browser-backed fetchers"

    assert devenv_nix =~ ~s(https://example.com),
           "sidecar-ready fetcher proof must target the deterministic example.com fixture page"

    assert devenv_nix =~ ~s(sidecar_health=pass),
           "sidecar-ready task must print a generic health success marker"

    assert devenv_nix =~ ~s(scrapling_fetchers=pass),
           "sidecar-ready task must print a generic fetcher success marker"

    refute devenv_nix =~ ~r/evidence_path|tee\s+-a/,
           "devenv.nix must not capture QA evidence from product/dev configuration"
  end

  test "devenv declares Phoenix, BEAM, asset, and sidecar toolchain command contract" do
    assert_contract_file("devenv.nix", "devenv module")

    devenv_nix = read!("devenv.nix")
    mix_exs = read!("mix.exs")

    declared_commands = declared_required_commands(devenv_nix)

    for command <- ~w(elixir mix psql inotifywait node uv python chromium) do
      assert command in declared_commands,
             "devenv command contract must include #{command}; dynamic shell evidence verifies it resolves"
    end

    assert Enum.uniq(declared_commands) == declared_commands,
           "devenv command contract must not list duplicate commands"

    assert devenv_nix =~ ~s(HIRAETH_DEVENV_BEAM_TARGET = "elixir-1.18-otp-27"),
           "devenv.nix must document that the BEAM shell target matches CI Elixir 1.18 / OTP 27"

    assert devenv_nix =~ ~s(MIX_BUILD_ROOT = ".devenv/mix-build"),
           "devenv shell Mix commands must use an isolated build path so host _build state cannot poison OTP 27 builds"

    assert mix_exs =~
             ~s("assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"]),
           "Phoenix asset installers must remain Mix-managed instead of being replaced by raw Nix asset packages"

    assert mix_exs =~ ~s("assets.build": ["compile", "tailwind hiraeth", "esbuild hiraeth"]),
           "Phoenix asset build must remain the existing Mix alias"

    refute devenv_nix =~ ~r/pkgs\.(?:esbuild|tailwindcss)\b/,
           "Nix/devenv must not replace Mix-managed Phoenix asset installers with raw asset packages"
  end

  defp assert_contract_file(relative_path, label) do
    file_path = path(relative_path)

    assert File.exists?(file_path),
           "#{label} is missing at #{relative_path}; Nix/devenv contract is incomplete"

    assert File.regular?(file_path), "#{relative_path} must be a regular file"
    assert File.read!(file_path) =~ ~r/\S/, "#{relative_path} must not be empty"
    assert_git_visible!(relative_path, label)
  end

  defp assert_git_visible!(relative_path, label) do
    assert git_visible?(relative_path),
           "#{label} at #{relative_path} must be Git-visible (tracked or staged), not ignored/untracked"
  end

  defp git_visible?(relative_path) do
    {_output, status} =
      System.cmd("git", ["ls-files", "--error-unmatch", "--", relative_path],
        cd: @repo_root,
        stderr_to_stdout: true
      )

    status == 0
  end

  defp declared_required_commands(devenv_nix) do
    pattern = ~r/HIRAETH_DEVENV_REQUIRED_COMMANDS\s*=\s*"(?<commands>[^"]+)";/

    case Regex.named_captures(pattern, devenv_nix) do
      %{"commands" => commands} -> String.split(commands)
      nil -> flunk("Expected HIRAETH_DEVENV_REQUIRED_COMMANDS declaration in devenv.nix")
    end
  end

  defp read!(relative_path), do: File.read!(path(relative_path))
  defp path(relative_path), do: Path.join(@repo_root, relative_path)

  defp database_defaults!(relative_path) do
    config = read!(relative_path)

    %{
      username: config_value!(config, :username),
      password: config_value!(config, :password),
      hostname: env_default!(config, "DATABASE_HOST"),
      port: config |> env_default!("DATABASE_PORT") |> String.to_integer(),
      database: database_name!(config)
    }
  end

  defp config_value!(config, key) do
    pattern = ~r/#{key}:\s*"(?<value>[^"]+)"/

    case Regex.named_captures(pattern, config) do
      %{"value" => value} -> value
      nil -> flunk("Expected #{inspect(key)} string config in database config")
    end
  end

  defp env_default!(config, env_name) do
    pattern = ~r/System\.get_env\("#{env_name}",\s*"(?<value>[^"]+)"\)/

    case Regex.named_captures(pattern, config) do
      %{"value" => value} -> value
      nil -> flunk("Expected #{env_name} default in database config")
    end
  end

  defp database_name!(config) do
    pattern = ~r/database:\s*"(?<value>hiraeth_(?:dev|test))/

    case Regex.named_captures(pattern, config) do
      %{"value" => value} -> value
      nil -> flunk("Expected hiraeth dev/test database name in database config")
    end
  end
end
