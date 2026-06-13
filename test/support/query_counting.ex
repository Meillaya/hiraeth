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
      queries = drain_query_count(ref, [])

      %{
        elapsed_microseconds: elapsed_microseconds,
        queries: queries,
        query_count: length(queries),
        result: result
      }
    after
      :telemetry.detach(handler_id)
      drain_query_count(ref, [])
    end
  end

  defp drain_query_count(ref, queries) do
    receive do
      {^ref, metadata} ->
        if ignored_query?(metadata) do
          drain_query_count(ref, queries)
        else
          drain_query_count(ref, [to_string(Map.get(metadata, :query, "")) | queries])
        end
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp ignored_query?(metadata) do
    query = to_string(Map.get(metadata, :query, ""))

    String.contains?(query, "schema_migrations") or
      String.contains?(query, "pg_catalog") or
      String.contains?(query, "information_schema")
  end
end
