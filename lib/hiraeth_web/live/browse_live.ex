defmodule HiraethWeb.BrowseLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Browse Catalog")
     |> assign(:query, "")
     |> assign(:page, 1)
     |> assign(:form, to_form(%{"query" => ""}, as: :search))
     |> assign(:all_count, 0)
     |> assign(:pagination, PublicCatalog.paginate([], 1))
     |> assign(:selected_book, nil)
     |> stream(:books, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_catalog(socket, params)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    {:noreply, push_patch(socket, to: ~p"/browse?q=#{query}")}
  end

  defp assign_catalog(socket, params) do
    query = Map.get(params, "q", "")
    page = Map.get(params, "page", "1")
    pagination = PublicCatalog.book_page(query, page)

    socket
    |> assign(:query, query)
    |> assign(:form, to_form(%{"query" => query}, as: :search))
    |> assign(:all_count, pagination.total_count)
    |> assign(:pagination, pagination)
    |> assign(:selected_book, List.first(pagination.entries))
    |> stream(:books, pagination.entries, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="browse-shell" class="grid grid-cols-1 gap-8 lg:grid-cols-12">
        <h1 class="sr-only">Browse Catalog</h1>

        <aside
          id="catalog-filters"
          class="space-y-6 rounded-sm border border-[#E7E2D8] bg-[#F5F2EB]/45 p-4 dark:border-[#2E2A27] dark:bg-[#1C1917]/35 lg:col-span-3 lg:sticky lg:top-24 lg:self-start"
        >
          <div class="border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-3">
            <h2 class="font-serif text-lg font-medium">Filter Stacks</h2>
          </div>
          <.form for={@form} id="browse-search-form" phx-change="search">
            <.input
              field={@form[:query]}
              type="text"
              label="Search catalog"
              placeholder="Title, contributor, ISBN…"
              phx-debounce="250"
            />
          </.form>
          <div class="rounded-sm border border-[#D8CFC0] bg-[#FCFAF7]/70 p-4 text-xs text-stone-700 dark:border-[#2E2A27] dark:bg-[#12110F]/70 dark:text-stone-300 space-y-2">
            <p class="font-mono uppercase tracking-wider">Known fields only</p>
            <p>Dates, translators, dimensions, and page counts remain absent until sourced.</p>
          </div>
        </aside>

        <section id="catalog-index" class="space-y-6 lg:col-span-5">
          <div class="border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-3 flex justify-between items-center">
            <h2 class="font-serif text-lg font-medium">Catalog Index</h2>
            <span class="font-mono text-xs text-stone-600 dark:text-stone-400">{@pagination.total_count} books</span>
          </div>

          <%= if @pagination.total_count == 0 do %>
            <div id="browse-empty">
              <CatalogComponents.empty_state
                id="catalog-empty"
                title="No catalog entries match"
                message="No catalog entries match the current query."
                context={query_context(@query)}
                action_label="Clear search"
                action_path="/browse"
              />
            </div>
          <% else %>
            <div id="catalog-grid" phx-update="stream" class="grid grid-cols-1 gap-5 sm:grid-cols-2">
              <CatalogComponents.edition_card
                :for={{dom_id, book} <- @streams.books}
                dom_id={dom_id}
                edition={book}
                id_prefix="catalog-card"
              />
            </div>
            <CatalogComponents.pagination
              page={@pagination.page}
              total_pages={@pagination.total_pages}
              base_path="/browse"
              query={@query}
            />
          <% end %>
        </section>

        <section id="book-reader" class="space-y-6 lg:col-span-4">
          <div class="border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-3">
            <h2 class="font-serif text-lg font-medium">Book Reader</h2>
          </div>

          <%= if @selected_book do %>
            <div class="sticky top-24 space-y-6 rounded-sm border border-[#E7E2D8] bg-[#FCFAF7]/65 p-4 shadow-sm dark:border-[#2E2A27] dark:bg-[#12110F]/55">
              <CatalogComponents.metadata_table book={@selected_book} />
              <CatalogComponents.provenance_badge source={@selected_book.source} />
            </div>
          <% else %>
            <CatalogComponents.empty_state
              id="book-reader-empty"
              title="No book selected"
              message="Adjust or clear the current search to select a sourced book for inspection."
              context={query_context(@query)}
              action_label="Clear search"
              action_path="/browse"
            />
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp query_context(""), do: nil
  defp query_context(query), do: "Current search: #{query}"
end
