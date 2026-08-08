# Single source of truth for test lane exclusion tags.
#
# `mix.exs` reads this file at compile time and assembles the `--exclude` flags
# for `mix test.fast` and the `--include` flags for `mix test.full` / `mix ci`.
# Adding a cost tag here automatically threads it through every lane without
# touching mix.exs by hand.
#
# Contract test: `test/hiraeth/mix_alias_contract_test.exs` asserts that the
# assembled alias matches this list exactly. If you change a tag name here,
# update the contract test's expected list in the same commit.
%{
  slow_tags: [
    :slow,
    :full_catalog,
    :integration,
    :performance,
    :browser,
    :public_catalog_full
  ]
}
