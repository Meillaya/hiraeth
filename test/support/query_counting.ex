defmodule Hiraeth.QueryCounting do
  @moduledoc false

  @repo_query_event [:hiraeth, :repo, :query]

  def measure(fun) when is_function(fun, 0) do
    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        @repo_query_event,
        fn _event, _measurements, metadata, _config ->
          send(parent, {ref, metadata})
        end,
        nil
      )

    try do
      {elapsed_microseconds, result} = :timer.tc(fun)

      %{
        elapsed_microseconds: elapsed_microseconds,
        query_count: drain_query_count(ref, 0),
        result: result
      }
    after
      :telemetry.detach(handler_id)
      drain_query_count(ref, 0)
    end
  end

  defp drain_query_count(ref, count) do
    receive do
      {^ref, metadata} ->
        if ignored_query?(metadata) do
          drain_query_count(ref, count)
        else
          drain_query_count(ref, count + 1)
        end
    after
      0 -> count
    end
  end

  defp ignored_query?(metadata) do
    query = to_string(Map.get(metadata, :query, ""))

    String.contains?(query, "schema_migrations") or
      String.contains?(query, "pg_catalog") or
      String.contains?(query, "information_schema")
  end
end
