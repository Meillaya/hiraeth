defmodule HiraethWeb.SearchLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

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
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="search-shell" class="archive-wash space-y-8 max-w-4xl mx-auto">
        <div class="text-center space-y-2">
          <span class="font-mono text-xs uppercase tracking-wider text-stone-500">Union Catalog Search</span>
          <h1 class="font-serif text-3xl font-medium tracking-tight">Index Search</h1>
          <p class="text-xs text-stone-500 max-w-md mx-auto">
            Search across sourced title, contributor, publisher, series, and ISBN fields.
          </p>
        </div>

        <div class="hiraeth-surface bg-[#F5F2EB] p-8 border border-[#D8CFC0] dark:bg-[#1C1917] dark:border-[#2E2A27] rounded-sm shadow-[0_24px_70px_-55px_rgba(28,25,23,0.7)]">
          <.form for={@form} id="catalog-search-form" phx-change="search">
            <.input
              field={@form[:query]}
              type="text"
              id="catalog-search-input"
              placeholder="Enter title, contributor, publisher..."
              phx-debounce="200"
            />
          </.form>

          <.form
            for={@filter_form}
            id="search-filter-form"
            phx-change="filter"
            class="mt-5 grid gap-3 sm:grid-cols-2"
          >
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
            <.input
              field={@filter_form[:role]}
              type="select"
              label="Role"
              options={[{"Any", ""}, {"Author", "author"}, {"Translator", "translator"}]}
            />
            <.input field={@filter_form[:format]} type="text" label="Format" placeholder="paperback" />
            <.input field={@filter_form[:language]} type="text" label="Language" placeholder="eng" />
            <.input field={@filter_form[:year]} type="text" label="Year" placeholder="2026" />
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
                      <div class="mt-0.5 space-y-0.5 text-xs text-stone-500 italic">
                        <p :if={role_names(book[:authors])}>by {role_names(book[:authors])}</p>
                        <p :if={role_names(book[:translators])}>
                          translated by {role_names(book[:translators])}
                        </p>
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

  defp role_names(contributors) when is_list(contributors) do
    contributors
    |> Enum.map(& &1[:name])
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> case do
      "" -> nil
      names -> names
    end
  end

  defp role_names(_contributors), do: nil

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
