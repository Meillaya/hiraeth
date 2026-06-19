defmodule HiraethWeb.SearchLive.Components do
  use HiraethWeb, :html

  alias HiraethWeb.CatalogComponents

  attr :form, :any, required: true
  attr :filter_form, :any, required: true
  attr :query, :string, required: true
  attr :results_count, :integer, required: true
  attr :streams, :map, required: true

  def search_shell(assigns) do
    ~H"""
    <div id="search-shell" class="archive-wash pb-12">
      <section class="mx-auto max-w-3xl py-12 text-center sm:py-16">
        <div class="font-serif text-4xl text-[var(--hiraeth-label)]">❧</div>
        <p class="qi-kicker mt-3 text-[var(--hiraeth-thread)]">Union catalog search</p>
        <h1 class="mt-3 font-serif text-4xl font-light tracking-tight text-[var(--hiraeth-ink)] sm:text-5xl">
          Search the archive
        </h1>
        <p class="qi-muted mx-auto mt-4 max-w-xl font-serif text-lg italic leading-relaxed">
          Title, contributor, translator, publisher, series, subject, or ISBN — only sourced fields are searched.
        </p>

        <.form for={@form} id="catalog-search-form" phx-change="search" class="mt-8">
          <.input
            field={@form[:query]}
            type="text"
            id="catalog-search-input"
            placeholder="Begin typing…"
            phx-debounce="200"
            class="qi-input w-full px-5 py-4 text-center font-serif text-xl"
          />
        </.form>
      </section>

      <section class="mx-auto grid max-w-6xl gap-8 lg:grid-cols-[15rem_minmax(0,1fr)] lg:items-start">
        <aside class="space-y-5 lg:sticky lg:top-24">
          <div class="border-b qi-divider pb-4">
            <h2 class="font-serif text-xl font-normal text-[var(--hiraeth-ink)]">Refine</h2>
            <p class="qi-muted mt-2 font-serif text-sm italic">
              Shareable filters keep the search surface precise without adding unsourced fields.
            </p>
          </div>
          <.filter_form form={@filter_form} query={@query} />
          <div class="qi-panel-soft space-y-2 p-4">
            <p class="qi-kicker text-[var(--hiraeth-thread)]">Known fields only</p>
            <p class="qi-muted font-serif text-sm leading-relaxed">
              The archive returns nothing rather than inventing a placeholder record.
            </p>
          </div>
        </aside>

        <.results results_count={@results_count} query={@query} streams={@streams} />
      </section>
    </div>
    """
  end

  defp filter_form(assigns) do
    ~H"""
    <.form for={@form} id="search-filter-form" phx-change="filter" class="space-y-4">
      <input type="hidden" name="filters[q]" value={@query} />
      <.input field={@form[:publisher]} type="text" label="Publisher" placeholder="deep-vellum" />
      <.input field={@form[:contributor]} type="text" label="Contributor" placeholder="david-bowles" />
      <div class="grid grid-cols-2 gap-3 lg:grid-cols-1 xl:grid-cols-2">
        <.input
          field={@form[:role]}
          type="select"
          label="Role"
          options={[{"Any", ""}, {"Author", "author"}, {"Translator", "translator"}]}
        />
        <.input field={@form[:format]} type="text" label="Format" placeholder="paperback" />
      </div>
      <div class="grid grid-cols-2 gap-3 lg:grid-cols-1 xl:grid-cols-2">
        <.input field={@form[:language]} type="text" label="Language" placeholder="eng" />
        <.input field={@form[:year]} type="text" label="Year" placeholder="2026" />
      </div>
      <.input field={@form[:subject]} type="text" label="Subject" placeholder="translation" />
      <.input field={@form[:series]} type="text" label="Series" placeholder="series slug" />
      <.input
        field={@form[:sort]}
        type="select"
        label="Sort"
        options={[{"Publication date, newest first", "newest"}]}
      />
    </.form>
    """
  end

  defp results(assigns) do
    ~H"""
    <section id="search-results" class="min-w-0 space-y-6">
      <div class="flex items-baseline justify-between gap-4 border-b qi-divider pb-4">
        <div>
          <p class="qi-kicker">{results_label(@query)}</p>
          <h2 class="mt-1 font-serif text-xl font-normal text-[var(--hiraeth-ink)]">
            Search results
          </h2>
        </div>
        <span class="font-mono text-xs text-[var(--hiraeth-muted)]">{@results_count} matches</span>
      </div>

      <%= if @results_count == 0 do %>
        <CatalogComponents.empty_state
          id="search-empty"
          title="No catalog entries match"
          message={empty_message(@query)}
          action_label="Clear search"
          action_path="/search"
        />
      <% else %>
        <div
          id="search-results-body"
          phx-update="stream"
          class="grid grid-cols-1 gap-7 sm:grid-cols-2 xl:grid-cols-3"
        >
          <article :for={{dom_id, book} <- @streams.results} id={dom_id} class="group space-y-3">
            <.link navigate={~p"/books/#{book.slug}"} class="qi-focus block rounded-sm">
              <CatalogComponents.book_cover book={book} />
            </.link>
            <div class="space-y-2 border-b qi-divider pb-4 transition duration-200 group-hover:border-[var(--hiraeth-thread)]">
              <p class="qi-label truncate text-[10px]">{book.publisher || "Publisher unknown"}</p>
              <h3 class="font-serif text-lg font-normal leading-tight text-[var(--hiraeth-ink)]">
                <.link
                  navigate={~p"/books/#{book.slug}"}
                  class="qi-focus rounded-sm hover:text-[var(--hiraeth-thread)]"
                >
                  {book.title}
                </.link>
              </h3>
              <div class="qi-muted space-y-0.5 text-sm">
                <p :if={role_names(book[:authors])}>by {role_names(book.authors)}</p>
                <p :if={role_names(book[:translators])}>
                  translated by {role_names(book.translators)}
                </p>
              </div>
              <div class="qi-muted flex flex-wrap gap-2 pt-1 font-mono text-[10px] uppercase tracking-wider">
                <span :if={book[:isbn]} class="break-all">{book.isbn}</span>
                <span :if={book[:source] && book.source[:provider]}>· {book.source.provider}</span>
              </div>
            </div>
          </article>
        </div>
      <% end %>
    </section>
    """
  end

  defp results_label(""), do: "Full index"
  defp results_label(query), do: "Results for “#{query}”"

  defp empty_message(""), do: "The archive has no sourced records for this filter set."

  defp empty_message(query),
    do:
      "No sourced record matches \"#{query}\". The archive did not fabricate a placeholder record."

  defp role_names(contributors) when is_list(contributors) do
    names = contributors |> Enum.map(& &1[:name]) |> Enum.reject(&is_nil/1) |> Enum.join(", ")
    if names == "", do: nil, else: names
  end

  defp role_names(_contributors), do: nil
end
