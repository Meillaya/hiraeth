defmodule HiraethWeb.SearchLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.PublicCatalog
  alias HiraethWeb.SearchLive.Components

  @filter_params ~w(q publisher role contributor format language subject series year sort)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Search Catalog")
     |> assign(:query, "")
     |> assign(:form, to_form(%{"query" => ""}, as: :search))
     |> assign(:results_count, 0)
     |> stream(:results, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_results(socket, params)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    filters = socket.assigns.filters |> Map.put("q", query)
    {:noreply, push_patch(socket, to: filtered_path("/search", filters))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: filtered_path("/search", filters))}
  end

  defp assign_results(socket, params) do
    filters = Map.take(params, @filter_params)
    query = Map.get(filters, "q", "")
    results = PublicCatalog.book_page(filters, 1)

    filter_form_params = blank_filter_params() |> Map.merge(filters) |> Map.put("q", query)

    socket
    |> assign(:query, query)
    |> assign(:filters, filter_form_params)
    |> assign(:form, to_form(%{"query" => query}, as: :search))
    |> assign(:filter_form, to_form(filter_form_params, as: :filters))
    |> assign(:results_count, results.total_count)
    |> stream(:results, results.entries, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{}}
      catalog_count={@results_count}
    >
      <Components.search_shell
        form={@form}
        filter_form={@filter_form}
        query={@query}
        results_count={@results_count}
        streams={@streams}
      />
    </Layouts.app>
    """
  end

  defp blank_filter_params do
    Map.new(@filter_params, &{&1, ""})
  end

  defp filtered_path(base_path, params) do
    params =
      params
      |> Map.take(@filter_params)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    case params do
      map when map == %{} -> base_path
      map -> base_path <> "?" <> URI.encode_query(map)
    end
  end
end
