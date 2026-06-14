defmodule HiraethWeb.BrowseLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

  @filter_params ~w(q publisher role contributor format language subject series year sort)

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
    filters = socket.assigns.filters |> Map.put("q", query) |> Map.delete("page")
    {:noreply, push_patch(socket, to: filtered_path("/browse", filters))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: filtered_path("/browse", filters))}
  end

  defp assign_catalog(socket, params) do
    filters = Map.take(params, @filter_params)
    query = Map.get(filters, "q", "")
    page = Map.get(params, "page", "1")
    pagination = PublicCatalog.book_page(filters, page)

    filter_form_params = blank_filter_params() |> Map.merge(filters) |> Map.put("q", query)

    socket
    |> assign(:query, query)
    |> assign(:filters, filter_form_params)
    |> assign(:form, to_form(%{"query" => query}, as: :search))
    |> assign(:filter_form, to_form(filter_form_params, as: :filters))
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

          <.form for={@filter_form} id="catalog-filter-form" phx-change="filter" class="space-y-3">
            <input type="hidden" name="filters[q]" value={@query} />
            <.input
              field={@filter_form[:publisher]}
              type="text"
              label="Publisher"
              placeholder="deep-vellum"
            />
            <.input
              field={@filter_form[:contributor]}
              type="text"
              label="Contributor"
              placeholder="david-bowles"
            />
            <div class="grid grid-cols-2 gap-3">
              <.input
                field={@filter_form[:role]}
                type="select"
                label="Role"
                options={[{"Any", ""}, {"Author", "author"}, {"Translator", "translator"}]}
              />
              <.input
                field={@filter_form[:format]}
                type="text"
                label="Format"
                placeholder="paperback"
              />
            </div>
            <div class="grid grid-cols-2 gap-3">
              <.input field={@filter_form[:language]} type="text" label="Language" placeholder="eng" />
              <.input field={@filter_form[:year]} type="text" label="Year" placeholder="2026" />
            </div>
            <.input
              field={@filter_form[:subject]}
              type="text"
              label="Subject"
              placeholder="translation"
            />
            <.input
              field={@filter_form[:series]}
              type="text"
              label="Series"
              placeholder="series slug"
            />
            <.input
              field={@filter_form[:sort]}
              type="select"
              label="Sort"
              options={[
                {"Title", "title"},
                {"Newest", "newest"},
                {"Author", "author"},
                {"Recently added", "recently_added"}
              ]}
            />
          </.form>
          <div class="rounded-sm border border-[#D8CFC0] bg-[#FCFAF7]/70 p-4 text-xs text-stone-700 dark:border-[#2E2A27] dark:bg-[#12110F]/70 dark:text-stone-300 space-y-2">
            <p class="font-mono uppercase tracking-wider">Known fields only</p>
            <p>Dates, dimensions, and page counts remain absent until sourced.</p>
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
              params={@filters}
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
