defmodule HiraethWeb.BookLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Book")}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    book = PublicCatalog.book(slug)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:page_title, if(book, do: book.title, else: "Book not found"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="book-detail-shell" class="space-y-10">
        <%= if @book do %>
          <.link
            navigate={~p"/browse"}
            class="inline-flex rounded-sm font-mono text-xs uppercase tracking-wider text-stone-900 transition hover:text-[#8C2D19] dark:text-stone-900 hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-[#8C2D19] dark:hover:text-[#E05A47]"
          >← Browse catalog</.link>

          <div class="grid grid-cols-1 lg:grid-cols-12 gap-10 items-start rounded-sm border border-[#D8CFC0] bg-[#FCFAF7] p-4 shadow-[0_28px_90px_-60px_rgba(28,25,23,0.65)] dark:border-[#2E2A27] dark:bg-[#12110F] sm:p-6">
            <aside class="lg:col-span-4 space-y-4 lg:sticky lg:top-24">
              <CatalogComponents.book_cover
                book={@book}
                class="max-w-sm mx-auto"
                loading="eager"
                fetchpriority="high"
                variant="hero"
              />
              <p
                :if={!@book[:cover]}
                id="missing-cover-note"
                class="rounded-sm border border-[#E7E2D8] bg-[#F5F2EB] p-3 text-center text-[10px] font-mono uppercase tracking-wider text-stone-600 dark:border-[#2E2A27] dark:bg-[#1C1917] dark:text-stone-400"
              >
                No sourced cover asset is attached; typographic cover fallback is shown.
              </p>
            </aside>

            <section class="lg:col-span-8 space-y-8">
              <div class="space-y-3 border-b border-[#D8CFC0] pb-6 dark:border-[#2E2A27]">
                <p
                  :if={@book[:publisher]}
                  class="font-mono text-xs uppercase tracking-[0.22em] text-[#8C2D19] dark:text-[#E05A47]"
                >
                  {@book.publisher}
                </p>
                <h1
                  id="book-title"
                  class="max-w-3xl font-serif text-4xl md:text-6xl font-medium tracking-tight text-stone-950 dark:text-stone-50"
                >
                  {@book.title}
                </h1>
                <p
                  :if={@book[:subtitle]}
                  class="font-serif italic text-xl text-stone-700 dark:text-stone-300"
                >
                  {@book.subtitle}
                </p>
                <div class="space-y-1 text-sm font-medium text-stone-700 dark:text-stone-300">
                  <p :if={role_names(@book[:authors])} id="book-authors">
                    by {role_names(@book[:authors])}
                  </p>
                  <p :if={role_names(@book[:translators])} id="book-translators">
                    translated by {role_names(@book[:translators])}
                  </p>
                </div>
              </div>

              <div id="book-identifiers" class="sr-only">
                {Enum.join(@book.identifiers, " ")}
              </div>

              <section
                :if={@book[:description]}
                id="book-description"
                class="max-w-2xl rounded-sm border-l-2 border-[#8C2D19]/65 bg-[#F5F2EB] py-1 pl-5 pr-4 font-serif text-[1.02rem] leading-8 text-stone-900 dark:bg-[#1C1917] dark:text-stone-100"
              >
                <h2 class="font-mono text-[10px] font-semibold uppercase tracking-[0.22em] text-stone-600 dark:text-stone-300">
                  Description
                </h2>
                <p class="mt-2">{@book.description}</p>
              </section>

              <section id="book-formats" class="space-y-3">
                <h2 class="font-serif text-xl font-medium text-stone-950 dark:text-stone-50">
                  Formats / editions
                </h2>
                <div class="overflow-hidden rounded-sm border border-[#D8CFC0] bg-[#FCFAF7]/75 shadow-sm dark:border-[#2E2A27] dark:bg-[#12110F]/70 divide-y divide-[#E7E2D8]/70 dark:divide-[#2E2A27]/70">
                  <div
                    :for={format <- @book.formats}
                    id={"book-format-#{format.edition_slug}"}
                    class="grid gap-2 p-4 text-sm transition hover:bg-[#F5F2EB]/70 sm:grid-cols-3 dark:hover:bg-[#1C1917]"
                  >
                    <div class="font-mono text-xs uppercase tracking-wider text-stone-600 dark:text-stone-300">
                      {format.format_label}
                    </div>
                    <div class="font-mono text-xs break-all text-stone-700 dark:text-stone-300">
                      {Enum.join(format.identifiers, ", ")}
                    </div>
                    <div class="text-stone-600 dark:text-stone-400">
                      {if format.published_on,
                        do: Calendar.strftime(format.published_on, "%Y-%m-%d"),
                        else: "Date unknown"}
                    </div>
                  </div>
                </div>
              </section>

              <section
                :if={Enum.any?(@book[:editorial_praise] || [])}
                id="book-editorial-praise"
                class="space-y-3 rounded-sm bg-[#F5F2EB] p-5 dark:bg-[#1C1917]"
              >
                <h2 class="font-serif text-xl font-medium text-stone-950 dark:text-stone-50">
                  Editorial praise
                </h2>
                <blockquote
                  :for={praise <- @book.editorial_praise}
                  class="border-l-2 border-[#8C2D19] pl-4 font-serif text-base leading-7 text-stone-700 dark:text-stone-300"
                >
                  <p>{praise["quote"] || praise[:quote]}</p>
                  <footer class="mt-2 font-mono text-[10px] uppercase tracking-wider">
                    {praise["source"] || praise[:source]}
                  </footer>
                </blockquote>
              </section>

              <.link
                :if={@book[:storefront_url]}
                id="book-storefront-cta"
                href={@book.storefront_url}
                class="inline-flex w-fit rounded-full border border-[#8C2D19] bg-[#8C2D19] px-4 py-2 font-mono text-xs font-bold uppercase tracking-wider text-white shadow-sm transition hover:-translate-y-0.5 hover:bg-transparent hover:text-[#8C2D19] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-[#8C2D19] dark:border-[#E05A47] dark:bg-[#E05A47] dark:text-[#12110F] dark:hover:bg-transparent dark:hover:text-[#E05A47]"
              >
                Publisher page
              </.link>

              <CatalogComponents.metadata_table book={@book} />
              <CatalogComponents.provenance_badge source={@book.source} />
            </section>
          </div>
        <% else %>
          <CatalogComponents.empty_state
            id="book-not-found"
            title="No book matches"
            message="No book matches that slug. The archive did not fabricate a placeholder record."
            action_label="Back to browse"
            action_path="/browse"
          />
        <% end %>
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
end
