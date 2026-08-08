defmodule Hiraeth.DevDatabaseUrlOverrideTest do
  use ExUnit.Case, async: false

  # The dev config is evaluated at compile time under MIX_ENV=test, but config/dev.exs
  # is scoped to :dev and stays unloaded. Config.Reader.read!/2 parses the file as if it
  # were MIX_ENV=dev, so we can assert the conditional branches without spawning a mix
  # subprocess or mixing dev config into the test env.
  @dev_config Path.expand("../../config/dev.exs", __DIR__)

  test "config/dev.exs falls back to standalone postgres when DATABASE_URL is unset" do
    with_db_url(nil, fn ->
      config = config_for(:dev)
      assert config[:database] == "hiraeth_dev"
      assert config[:hostname] == "localhost"
      assert config[:port] == 54_320
    end)
  end

  test "config/dev.exs routes to DATABASE_URL when set so `railway run -- mix ...` reaches the live DB" do
    db_url = "postgresql://u:p@h:5432/dbname"

    with_db_url(db_url, fn ->
      config = config_for(:dev)
      assert config[:url] == db_url
    end)
  end

  test "config/dev.exs does not keep the localhost hostname when DATABASE_URL is set" do
    db_url = "postgresql://u:p@h:5432/dbname"

    with_db_url(db_url, fn ->
      config = config_for(:dev)
      refute config[:hostname] == "localhost"
      refute config[:hostname] == "127.0.0.1"
    end)
  end

  defp config_for(env) do
    @dev_config
    |> Config.Reader.read!(env: env)
    |> Keyword.get(:hiraeth)
    |> Keyword.get(Hiraeth.Repo)
  end

  defp with_db_url(value, fun) do
    saved = System.get_env("DATABASE_URL")

    try do
      case value do
        nil -> System.delete_env("DATABASE_URL")
        v -> System.put_env("DATABASE_URL", v)
      end

      fun.()
    after
      case saved do
        nil -> System.delete_env("DATABASE_URL")
        v -> System.put_env("DATABASE_URL", v)
      end
    end
  end
end
