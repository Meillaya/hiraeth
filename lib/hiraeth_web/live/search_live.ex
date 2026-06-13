defmodule HiraethWeb.SearchLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    results = PublicCatalog.book_page("", 1)

    {:ok,
     socket
     |> assign(:page_title, "Search Catalog")
     |> assign(:query, "")
     |> assign(:form, to_form(%{"query" => ""}, as: :search))
     |> assign(:results_count, results.total_count)
     |> stream(:results, results.entries)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    results = PublicCatalog.book_page(query, 1)

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:form, to_form(%{"query" => query}, as: :search))
     |> assign(:results_count, results.total_count)
     |> stream(:results, results.entries, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="search-shell" class="space-y-8 max-w-4xl mx-auto">
        <div class="text-center space-y-2">
          <span class="font-mono text-xs uppercase tracking-wider text-stone-500">Union Catalog Search</span>
          <h1 class="font-serif text-3xl font-medium tracking-tight">Index Search</h1>
          <p class="text-xs text-stone-500 max-w-md mx-auto">
            Search across sourced title, contributor, publisher, series, and ISBN fields.
          </p>
        </div>

        <div class="bg-[#F5F2EB] p-8 border border-[#D8CFC0] dark:bg-[#1C1917] dark:border-[#2E2A27] rounded-sm shadow-[0_24px_70px_-55px_rgba(28,25,23,0.7)]">
          <.form for={@form} id="catalog-search-form" phx-change="search">
            <.input
              field={@form[:query]}
              type="text"
              id="catalog-search-input"
              placeholder="Enter title, contributor, publisher..."
              phx-debounce="200"
            />
          </.form>
          <div class="flex justify-between items-center text-[10px] font-mono text-stone-600 dark:text-stone-400 mt-3">
            <span>REAL-TIME CATALOG FILTER</span>
            <span>{@results_count} MATCHES</span>
          </div>
        </div>

        <div id="search-results" class="space-y-4">
          <div class="border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-2 flex justify-between items-center text-sm">
            <span class="font-serif font-medium">Search Results</span>
            <span class="font-mono text-xs text-stone-600 dark:text-stone-400">{@results_count} matches</span>
          </div>

          <%= if @results_count == 0 do %>
            <CatalogComponents.empty_state
              id="search-empty"
              message={"No catalog entries match search term \"#{@query}\"."}
            />
          <% else %>
            <div class="overflow-hidden rounded-sm border border-[#E7E2D8] bg-[#FCFAF7]/65 dark:border-[#2E2A27] dark:bg-[#12110F]/50">
              <table class="w-full text-left text-sm border-collapse">
                <thead class="hidden sm:table-header-group">
                  <tr class="border-b border-[#E7E2D8] dark:border-[#2E2A27]">
                    <th class="py-3 font-mono text-xs uppercase text-stone-500 font-semibold w-1/3">
                      Title & Contributor
                    </th>
                    <th class="py-3 font-mono text-xs uppercase text-stone-500 font-semibold w-1/4">
                      Publisher
                    </th>
                    <th class="py-3 font-mono text-xs uppercase text-stone-500 font-semibold">
                      ISBN
                    </th>
                    <th class="py-3 font-mono text-xs uppercase text-stone-500 font-semibold text-right">
                      Source
                    </th>
                  </tr>
                </thead>
                <tbody
                  id="search-results-body"
                  phx-update="stream"
                  class="block divide-y divide-[#E7E2D8]/50 dark:divide-[#2E2A27]/50 sm:table-row-group"
                >
                  <tr
                    :for={{dom_id, book} <- @streams.results}
                    id={dom_id}
                    class="group block space-y-3 p-4 transition-colors hover:bg-[#F5F2EB]/70 dark:hover:bg-[#1C1917] sm:table-row sm:space-y-0 sm:p-0"
                  >
                    <td class="block sm:table-cell sm:py-4 sm:pr-4">
                      <span class="mb-1 block font-mono text-[10px] font-semibold uppercase tracking-wider text-stone-500 sm:hidden">
                        Title
                      </span>
                      <div class="font-serif font-medium text-stone-900 dark:text-stone-100">
                        <.link
                          navigate={~p"/books/#{book.slug}"}
                          class="rounded-sm hover:text-[#8C2D19] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#8C2D19] dark:hover:text-[#E05A47]"
                        >
                          {book.title}
                        </.link>
                      </div>
                      <div :if={book[:author]} class="text-xs text-stone-500 italic mt-0.5">
                        {book.author}
                      </div>
                    </td>
                    <td class="block text-stone-700 dark:text-stone-300 sm:table-cell sm:py-4 sm:pr-4">
                      <span class="mb-1 block font-mono text-[10px] font-semibold uppercase tracking-wider text-stone-500 sm:hidden">
                        Publisher
                      </span>
                      {book.publisher}
                    </td>
                    <td class="block break-all font-mono text-xs text-stone-500 sm:table-cell sm:py-4">
                      <span class="mb-1 block font-mono text-[10px] font-semibold uppercase tracking-wider text-stone-500 sm:hidden">
                        ISBN
                      </span>
                      {book.isbn}
                    </td>
                    <td class="block break-all font-mono text-xs text-stone-700 dark:text-stone-300 sm:table-cell sm:py-4 sm:text-right sm:text-sm">
                      <span class="mb-1 block font-mono text-[10px] font-semibold uppercase tracking-wider text-stone-500 sm:hidden">
                        Source
                      </span>
                      {book.source && book.source.provider}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
