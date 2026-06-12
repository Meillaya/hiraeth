# Seeds the curated real publisher pilot catalog for local development.
# Run with: mix run priv/repo/seeds.exs

{:ok, summary} = Hiraeth.RealCatalogFixtures.seed!()
IO.puts("seeded real publisher catalog: #{summary.editions} editions")
