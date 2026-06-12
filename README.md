# Hiraeth

Hiraeth is a Phoenix LiveView and Ash catalog for browsing curated independent publisher and bookstore book metadata with provenance-aware imports, cover attribution, and admin review tools.

## Run locally

Requirements: Elixir/OTP, Docker, and Mix.

```sh
docker compose up -d postgres
mix deps.get
mix ash.migrate
mix run priv/repo/seeds.exs
mix phx.server
```

Open <http://localhost:4000>.

## Verify/build

```sh
mix test
mix compile --warnings-as-errors
make verify
```
