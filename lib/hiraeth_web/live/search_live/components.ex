defmodule HiraethWeb.SearchLive.Components do
  use HiraethWeb, :html

  alias HiraethWeb.CatalogComponents

  attr :form, :any, required: true
  attr :query, :string, required: true
  attr :filters, :map, required: true
  attr :pagination, :map, required: true
  attr :results_count, :integer, required: true
  attr :streams, :map, required: true

  def search_shell(assigns) do
    ~H"""
    <div id="search-shell" class="archive-wash pb-12">
      <section class="mx-auto max-w-3xl py-12 text-center sm:py-16">
        <div class="font-serif text-3xl text-[var(--hiraeth-label)]">❧</div>
        <h1 class="mt-5 font-serif text-4xl font-light tracking-tight text-[var(--hiraeth-ink)] sm:text-5xl">
          Search the archive
        </h1>
        <p class="qi-muted mx-auto mt-4 max-w-xl font-serif text-lg italic leading-relaxed">
          Title, contributor, translator, publisher, or ISBN.
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

      <.results
        results_count={@results_count}
        query={@query}
        streams={@streams}
        filters={@filters}
        pagination={@pagination}
      />
    </div>
    """
  end

  attr :results_count, :integer, required: true
  attr :query, :string, required: true
  attr :streams, :map, required: true
  attr :filters, :map, required: true
  attr :pagination, :map, required: true

  defp results(assigns) do
    ~H"""
    <section id="search-results" class="mx-auto max-w-6xl space-y-7">
      <div class="flex items-end justify-between gap-4 border-b qi-divider pb-4">
        <p class="qi-kicker">{results_label(@query)}</p>
        <span class="font-mono text-xs text-[var(--hiraeth-muted)]">{@results_count} found</span>
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
          class="grid grid-cols-2 gap-x-6 gap-y-10 sm:grid-cols-3 lg:grid-cols-4"
        >
          <article :for={{dom_id, book} <- @streams.results} id={dom_id} class="group space-y-3">
            <.link navigate={~p"/books/#{book.slug}"} class="qi-focus block rounded-sm">
              <CatalogComponents.book_cover book={book} />
            </.link>
            <div class="space-y-1.5">
              <h3 class="font-serif text-base font-normal leading-tight text-[var(--hiraeth-ink)]">
                <.link
                  navigate={~p"/books/#{book.slug}"}
                  class="qi-focus rounded-sm hover:text-[var(--hiraeth-thread)]"
                >
                  {book.title}
                </.link>
              </h3>
              <p :if={role_names(book[:authors])} class="qi-muted truncate text-xs">
                {role_names(book.authors)}
              </p>
              <p :if={role_names(book[:translators])} class="qi-muted truncate text-xs">
                tr. {role_names(book.translators)}
              </p>
              <p :if={format_summary(book[:formats])} class="qi-label truncate text-[10px]">
                {format_summary(book.formats)}
              </p>
            </div>
          </article>
        </div>

        <CatalogComponents.pagination
          :if={@pagination.total_pages > 1}
          page={@pagination.page}
          total_pages={@pagination.total_pages}
          base_path="/search"
          params={@filters}
        />
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

  defp format_summary(formats) when is_list(formats) do
    formats
    |> Enum.map(fn format -> format[:format_label] || format_label(format[:format]) end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp format_summary(_formats), do: nil

  defp role_names(contributors) when is_list(contributors) do
    names = contributors |> Enum.map(& &1[:name]) |> Enum.reject(&is_nil/1) |> Enum.join(", ")
    if names == "", do: nil, else: names
  end

  defp role_names(_contributors), do: nil

  defp format_label(nil), do: nil

  defp format_label(format) do
    format
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
