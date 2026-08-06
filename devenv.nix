{ pkgs, ... }:

let
  chromiumExecutable = "${pkgs.chromium}/bin/chromium";
  scraplingBrowsers = pkgs.runCommand "hiraeth-scrapling-browsers" { } ''
    set -eu
    mkdir -p "$out/chromium-1223/chrome-linux64"
    mkdir -p "$out/chromium_headless_shell-1223/chrome-linux64"
    ln -s ${pkgs.chromium}/bin/chromium "$out/chromium-1223/chrome-linux64/chrome"
    ln -s ${pkgs.chromium}/bin/chromium "$out/chromium_headless_shell-1223/chrome-linux64/chrome-headless-shell"
  '';
in
{
  packages = [
    pkgs.beam.packages.erlang_27.elixir_1_18
    pkgs.beam.interpreters.erlang_27
    pkgs.postgresql_16
    pkgs.inotify-tools
    pkgs.nodejs_22
    pkgs.python312
    pkgs.uv
  ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
    pkgs.chromium
  ];

  env = {
    HIRAETH_DEVENV_BEAM_TARGET = "elixir-1.18-otp-27";
    HIRAETH_DEVENV_REQUIRED_COMMANDS = "elixir mix psql inotifywait node uv python chromium";
    HIRAETH_SIDECAR_BROWSER_EXECUTABLE = chromiumExecutable;
    PLAYWRIGHT_BROWSERS_PATH = "${scraplingBrowsers}";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
    MIX_BUILD_ROOT = ".devenv/mix-build";
    DATABASE_HOST = "localhost";
    DATABASE_PORT = "54320";
    DATABASE_USER = "postgres";
    DATABASE_PASSWORD = "postgres";
    DATABASE_NAME = "hiraeth_dev";
    PGUSER = "postgres";
    PGPASSWORD = "postgres";
    # Autonomous ingestion kill-switch: local dev never auto-fetches publisher
    # sites. Operators trigger runs with `mix hiraeth.ingest`.
    HIRAETH_SCHEDULED_INGEST = "false";
  };



  # Use a devenv-managed PostgreSQL process instead of the built-in PostgreSQL service because
  # devenv 2.1.2 socket-activates declared service ports before PostgreSQL binds,
  # which can make readiness pass against the wrapper and then fail with
  # address-in-use. The explicit process owns port 54320 itself.

  processes."hiraeth-postgres" = {
    exec = ''
            set -euo pipefail
            export PGDATA="$DEVENV_STATE/hiraeth-postgres"
            export PGHOST="127.0.0.1"
            export PGPORT="54320"
            export PGUSER="postgres"
            export PGPASSWORD="postgres"
            runtime_dir="$DEVENV_RUNTIME/hiraeth-postgres"
            init_runtime_dir="$DEVENV_RUNTIME/hiraeth-postgres-init"
            mkdir -p "$runtime_dir" "$init_runtime_dir"

            if [ ! -d "$PGDATA" ]; then
              initdb --locale=C --encoding=UTF8 --username=postgres
              cat > "$PGDATA/postgresql.conf" <<EOF
      listen_addresses = '127.0.0.1'
      port = 54320
      unix_socket_directories = '$runtime_dir'
      EOF
              old_pg_host="$PGHOST"
              export PGHOST="$init_runtime_dir"
              pg_ctl -D "$PGDATA" -w start -o "-c unix_socket_directories=$init_runtime_dir -c listen_addresses= -p 54320"
              psql --dbname postgres -v ON_ERROR_STOP=1 <<'SQL'
      ALTER ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';
      CREATE DATABASE hiraeth_dev OWNER postgres;
      CREATE DATABASE hiraeth_test OWNER postgres;
      SQL
              pg_ctl -D "$PGDATA" -m fast -w stop
              export PGHOST="$old_pg_host"
            fi

            exec postgres -D "$PGDATA"
    '';
    ready = {
      exec = ''
        PGPASSWORD=postgres PGPORT=54320 pg_isready -h "$DEVENV_RUNTIME/hiraeth-postgres" -U postgres
      '';
      initial_delay = 2;
      period = 2;
      probe_timeout = 4;
      failure_threshold = 60;
      timeout = 120;
    };
  };

  processes."scrapling-sidecar" = {
    exec = ''
      set -euo pipefail
      export HIRAETH_SIDECAR_BROWSER_EXECUTABLE="${chromiumExecutable}"
      export PLAYWRIGHT_BROWSERS_PATH="${scraplingBrowsers}"
      export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
      export XDG_CACHE_HOME="$DEVENV_STATE/scrapling-cache"
      export HOME="$DEVENV_STATE/sidecar-home"
      mkdir -p "$XDG_CACHE_HOME" "$HOME"
      cd sidecar
      exec uv run --extra dev uvicorn app.main:app --host 127.0.0.1 --port 8000
    '';
    ready = {
      http.get = {
        host = "127.0.0.1";
        port = 8000;
        path = "/health/";
      };
      initial_delay = 2;
      period = 2;
      probe_timeout = 5;
      timeout = 120;
      failure_threshold = 60;
    };
  };

  processes.phoenix = {
    exec = ''
      set -euo pipefail
      timeout 120 bash -c 'until pg_isready -h 127.0.0.1 -p 54320 -U postgres; do sleep 2; done'
      mix ecto.create --quiet || true
      mix ecto.migrate --quiet
      exec mix phx.server
    '';
    ready = {
      http.get = {
        host = "127.0.0.1";
        port = 4000;
        path = "/";
      };
      initial_delay = 2;
      period = 2;
      probe_timeout = 5;
      timeout = 300;
      failure_threshold = 150;
    };
  };

  tasks."test:phoenix-ready" = {
    description = "Verify the devenv-managed Phoenix endpoint returns HTTP 200 or redirect.";
    after = [
      "devenv:processes:hiraeth-postgres"
      "devenv:processes:phoenix"
    ];
    before = [ "devenv:enterTest" ];
    exec = ''
      set -euo pipefail
      pg_isready -h 127.0.0.1 -p 54320 -U postgres
      status="$(${pkgs.curl}/bin/curl --silent --show-error --location --output "$DEVENV_STATE/phoenix-ready-home.html" --write-out "%{http_code}" http://127.0.0.1:4000/)"

      case "$status" in
        200|301|302|303|307|308)
          echo "Phoenix ready at http://127.0.0.1:4000/ with HTTP $status"
          ;;
        *)
          echo "Phoenix readiness probe failed with HTTP $status" >&2
          exit 1
          ;;
      esac
    '';
  };

  tasks."test:sidecar-ready" = {
    description = "Verify the devenv-managed Scrapling sidecar imports, serves health, and runs browser-backed fetchers without Docker.";
    after = [
      "devenv:processes:scrapling-sidecar"
    ];
    before = [ "devenv:enterTest" ];
    exec = ''
            set -euo pipefail

            export HIRAETH_SIDECAR_BROWSER_EXECUTABLE="${chromiumExecutable}"
            export PLAYWRIGHT_BROWSERS_PATH="${scraplingBrowsers}"
            export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
            export XDG_CACHE_HOME="$DEVENV_STATE/scrapling-cache"
            export HOME="$DEVENV_STATE/sidecar-home"
            mkdir -p "$XDG_CACHE_HOME" "$HOME"

            ${pkgs.curl}/bin/curl --fail --silent --show-error http://127.0.0.1:8000/health/
            echo "sidecar_health=pass" >&2

            cd sidecar

            cat > /tmp/hiraeth-sidecar-ready-fetchers.py <<'PY'
      import sys

      from scrapling.fetchers import DynamicFetcher, StealthyFetcher


      def response_text(page):
          raw_text = getattr(page, "text", "")
          text_value = str(raw_text() if callable(raw_text) else raw_text)
          if text_value.strip():
              return text_value

          body = getattr(page, "body", b"")
          if isinstance(body, bytes):
              return body.decode("utf-8", errors="replace")

          return str(body or "")


      for fetcher in (StealthyFetcher, DynamicFetcher):
          page = fetcher.fetch(
              "https://example.com",
              timeout=20000,
              google_search=False,
              network_idle=True,
          )
          status = getattr(page, "status", None)
          text = response_text(page)
          assert status in (200, None), (fetcher.__name__, status)
          assert "Example Domain" in text, fetcher.__name__
          print(f"{fetcher.__name__}: status={status} text_includes_example_domain=True", file=sys.stderr)

      print("scrapling_fetchers=pass", file=sys.stderr)
      PY
            uv run python /tmp/hiraeth-sidecar-ready-fetchers.py
            echo "sidecar-ready=pass" >&2
    '';
  };

  enterTest = ''
    pg_isready -h 127.0.0.1 -p 54320 -U postgres
  '';
}
