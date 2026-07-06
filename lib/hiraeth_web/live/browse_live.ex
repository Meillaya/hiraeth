defmodule HiraethWeb.BrowseLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.BrowseLive.Components
  alias HiraethWeb.CatalogFilterParams
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Browse Catalog")
     |> assign(:query, "")
     |> assign(:page, 1)
     |> assign(:form, to_form(%{"query" => ""}, as: :search))
     |> assign(:filter_form, to_form(CatalogFilterParams.blank(), as: :filters))
     |> assign(:filters, CatalogFilterParams.blank())
     |> assign(:all_count, 0)
     |> assign(:publisher_facets, PublicCatalog.publishers())
     |> assign(:pagination, PublicCatalog.paginate([], 1))
     |> assign(:page_books, [])
     |> assign(:selected_book, nil)
     |> stream(:books, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_catalog(socket, params)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    filters = socket.assigns.filters |> Map.put("q", query) |> Map.delete("page")
    {:noreply, push_patch(socket, to: CatalogFilterParams.filtered_path("/browse", filters))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: CatalogFilterParams.filtered_path("/browse", filters))}
  end

  def handle_event("select", %{"slug" => slug}, socket) do
    selected =
      Enum.find(socket.assigns.page_books, &(&1.slug == slug)) || socket.assigns.selected_book

    {:noreply, assign(socket, :selected_book, selected)}
  end

  defp assign_catalog(socket, params) do
    filter_params = CatalogFilterParams.from_request(params)
    pagination = PublicCatalog.book_page(filter_params.filters, filter_params.page)
    selected_book = selected_book_for(pagination.entries, socket.assigns[:selected_book])

    socket
    |> assign(:query, filter_params.query)
    |> assign(:filters, filter_params.form_params)
    |> assign(:form, to_form(%{"query" => filter_params.query}, as: :search))
    |> assign(:filter_form, to_form(filter_params.form_params, as: :filters))
    |> assign(:all_count, pagination.total_count)
    |> assign(:pagination, pagination)
    |> assign(:page_books, pagination.entries)
    |> assign(:selected_book, selected_book)
    |> stream(:books, pagination.entries, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{}}
      catalog_count={@all_count}
    >
      <Components.browse_shell
        form={@form}
        filter_form={@filter_form}
        pagination={@pagination}
        streams={@streams}
        query={@query}
        filters={@filters}
        selected_book={@selected_book}
        publisher_facets={@publisher_facets}
      />
    </Layouts.app>
    """
  end

  defp selected_book_for([], _previous), do: nil

  defp selected_book_for(entries, previous) do
    Enum.find(entries, &(&1.slug == previous[:slug])) || List.first(entries)
  end
end
