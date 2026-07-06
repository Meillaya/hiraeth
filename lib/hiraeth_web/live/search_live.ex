defmodule HiraethWeb.SearchLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogFilterParams
  alias HiraethWeb.PublicCatalog
  alias HiraethWeb.SearchLive.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Search Catalog")
     |> assign(:query, "")
     |> assign(:form, to_form(%{"query" => ""}, as: :search))
     |> assign(:filters, CatalogFilterParams.blank())
     |> assign(:pagination, PublicCatalog.paginate([], 1))
     |> assign(:results_count, 0)
     |> stream(:results, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_results(socket, params)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    filters = socket.assigns.filters |> Map.put("q", query) |> Map.delete("page")
    {:noreply, push_patch(socket, to: CatalogFilterParams.filtered_path("/search", filters))}
  end

  defp assign_results(socket, params) do
    filter_params = CatalogFilterParams.from_request(params)
    results = PublicCatalog.book_page(filter_params.filters, filter_params.page)

    socket
    |> assign(:query, filter_params.query)
    |> assign(:filters, filter_params.form_params)
    |> assign(:form, to_form(%{"query" => filter_params.query}, as: :search))
    |> assign(:pagination, results)
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
        query={@query}
        filters={@filters}
        pagination={@pagination}
        results_count={@results_count}
        streams={@streams}
      />
    </Layouts.app>
    """
  end
end
