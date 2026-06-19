defmodule HiraethWeb.BrowseLive.Components do
  use HiraethWeb, :html

  alias HiraethWeb.CatalogComponents

  def browse_shell(assigns) do
    ~H"""
    <main id="browse-shell" class="pb-8">
      <div class="grid grid-cols-1 gap-8 lg:grid-cols-[14.5rem_minmax(0,1fr)_21rem] lg:items-start lg:gap-11">
        <.filter_rail
          form={@form}
          filter_form={@filter_form}
          query={@query}
          publisher_facets={@publisher_facets}
        />
        <.catalog_index pagination={@pagination} streams={@streams} query={@query} filters={@filters} />
        <.reader_rail book={@selected_book} query={@query} />
      </div>
    </main>
    """
  end

  defp filter_rail(assigns) do
    ~H"""
    <aside id="catalog-filters" class="space-y-6 lg:sticky lg:top-24">
      <div class="border-b qi-divider pb-4">
        <h2 class="font-serif text-xl font-normal text-[var(--hiraeth-ink)]">Filter</h2>
      </div>
      <.form for={@form} id="browse-search-form" phx-change="search" class="space-y-2">
        <.input
          field={@form[:query]}
          type="text"
          label="Search catalog"
          placeholder="Title, contributor, ISBN…"
          phx-debounce="250"
        />
      </.form>
      <.form for={@filter_form} id="catalog-filter-form" phx-change="filter" class="sr-only">
        <input type="hidden" name="filters[q]" value={@query} />
        <input
          type="text"
          class="sr-only"
          name="filters[publisher]"
          value={@filter_form[:publisher].value || ""}
        />
        <input
          type="hidden"
          name="filters[contributor]"
          value={@filter_form[:contributor].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          name="filters[role]"
          value={@filter_form[:role].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          name="filters[format]"
          value={@filter_form[:format].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          name="filters[language]"
          value={@filter_form[:language].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          name="filters[year]"
          value={@filter_form[:year].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          name="filters[subject]"
          value={@filter_form[:subject].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          name="filters[series]"
          value={@filter_form[:series].value || ""}
        />
        <select name="filters[sort]">
          <option value="newest" selected={@filter_form[:sort].value in [nil, "", "newest"]}>
            Publication date, newest first
          </option>
        </select>
      </.form>
      <div class="space-y-3">
        <p class="qi-label">Publisher</p>
        <div class="flex flex-col gap-2">
          <.link
            :for={publisher <- @publisher_facets}
            navigate={~p"/browse?publisher=#{publisher.slug}"}
            class="qi-focus flex justify-between gap-3 rounded-sm text-[13px] text-[var(--hiraeth-ink)] transition-colors hover:text-[var(--hiraeth-thread)]"
          >
            <span class="truncate">{publisher.name}</span>
            <span class="font-mono text-[var(--hiraeth-label)]">{publisher.editions_count}</span>
          </.link>
        </div>
      </div>
      <div class="space-y-3">
        <p class="qi-label">Format</p>
        <div class="flex flex-col gap-2 text-[13px] text-[var(--hiraeth-ink)]">
          <.link
            navigate={~p"/browse?format=paperback"}
            class="qi-focus flex justify-between rounded-sm transition-colors hover:text-[var(--hiraeth-thread)]"
          >
            <span>Paperback</span><span class="font-mono text-[var(--hiraeth-label)]">—</span>
          </.link>
          <.link
            navigate={~p"/browse?format=hardcover"}
            class="qi-focus flex justify-between rounded-sm transition-colors hover:text-[var(--hiraeth-thread)]"
          >
            <span>Hardcover</span><span class="font-mono text-[var(--hiraeth-label)]">—</span>
          </.link>
          <.link
            navigate={~p"/browse?format=ebook"}
            class="qi-focus flex justify-between rounded-sm transition-colors hover:text-[var(--hiraeth-thread)]"
          >
            <span>Ebook</span><span class="font-mono text-[var(--hiraeth-label)]">—</span>
          </.link>
        </div>
      </div>
      <div class="qi-panel-soft space-y-2 p-4">
        <p class="qi-kicker text-[var(--hiraeth-thread)]">Known fields only</p>
        <p class="font-serif text-sm leading-relaxed text-[var(--hiraeth-muted)]">
          Dates, translators, descriptions, and cover assets appear only when a source supplies them. Unsourced covers fall back to type.
        </p>
      </div>
    </aside>
    """
  end

  defp catalog_index(assigns) do
    ~H"""
    <section id="catalog-index" class="min-w-0 space-y-6">
      <div class="flex items-baseline justify-between gap-4 border-b qi-divider pb-4">
        <h1 class="font-serif text-xl font-normal text-[var(--hiraeth-ink)]">Catalog Index</h1>
        <span class="font-mono text-xs text-[var(--hiraeth-muted)]">{@pagination.total_count} books</span>
      </div>
      <%= if @pagination.total_count == 0 do %>
        <div id="browse-empty">
          <CatalogComponents.empty_state
            id="catalog-empty"
            title="No catalog entries match"
            message="The archive did not fabricate a placeholder record. Adjust or clear the current filters."
            context={query_context(@query)}
            action_label="Clear search"
            action_path="/browse"
          />
        </div>
      <% else %>
        <div id="catalog-grid" phx-update="stream" class="grid grid-cols-1 gap-7 sm:grid-cols-2">
          <.book_card :for={{dom_id, book} <- @streams.books} dom_id={dom_id} book={book} />
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
    """
  end

  defp book_card(assigns) do
    ~H"""
    <article id={@dom_id} class="group space-y-3">
      <button
        type="button"
        phx-click="select"
        phx-value-slug={@book.slug}
        class="block w-full rounded-sm text-left qi-focus"
        aria-label={"Select #{@book.title} for the volume reader"}
      >
        <div class="relative">
          <CatalogComponents.book_cover book={@book} />
          <span class="absolute left-2 top-2 rounded-sm border border-[var(--hiraeth-line)] bg-[color-mix(in_oklab,var(--hiraeth-paper)_82%,transparent)] px-2 py-1 font-mono text-[8px] uppercase tracking-[0.14em] text-[var(--hiraeth-muted)] backdrop-blur">
            {publisher_short(@book[:publisher])}
          </span>
        </div>
      </button>
      <div class="space-y-1.5">
        <h4 class="font-serif text-base font-normal leading-tight tracking-tight text-[var(--hiraeth-ink)]">
          <.link
            navigate={~p"/books/#{@book.slug}"}
            class="qi-focus rounded-sm hover:text-[var(--hiraeth-thread)]"
          >{@book.title}</.link>
        </h4>
        <div class="space-y-0.5 text-xs text-[var(--hiraeth-muted)]">
          <p :if={role_names(@book[:authors])} class="truncate">{role_names(@book.authors)}</p>
          <p :if={role_names(@book[:translators])} class="truncate">
            tr. {role_names(@book.translators)}
          </p>
        </div>
        <p class="qi-label truncate text-[10px]">
          {@book.publisher || "Publisher unknown"}
        </p>
        <div class="sr-only">
          <p :if={role_names(@book[:authors])}>by {role_names(@book.authors)}</p>
          <p :if={role_names(@book[:translators])}>
            translated by {role_names(@book.translators)}
          </p>
          <p :if={@book[:description]}>{description_excerpt(@book.description, 180)}</p>
          <p :for={format <- @book[:formats] || []}>
            {format.format} {Enum.join(format.identifiers, ", ")}
          </p>
        </div>
      </div>
    </article>
    """
  end

  defp reader_rail(assigns) do
    ~H"""
    <aside id="book-reader" class="space-y-6 lg:sticky lg:top-24">
      <div class="border-b qi-divider pb-4">
        <h2 class="font-serif text-xl font-normal text-[var(--hiraeth-ink)]">Volume Reader</h2>
      </div>
      <%= if @book do %>
        <.selected_reader book={@book} />
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
    </aside>
    """
  end

  defp selected_reader(assigns) do
    assigns =
      assigns
      |> assign(:authors, role_names(assigns.book[:authors]))
      |> assign(:cover_image_src, reader_cover_src(assigns.book[:cover]))

    ~H"""
    <div class="space-y-6">
      <div class="flex items-start gap-4">
        <div class="w-24 flex-none">
          <img
            :if={@cover_image_src}
            src={@cover_image_src}
            alt={"Cover for #{@book.title}"}
            loading="lazy"
            decoding="async"
            width="160"
            height="240"
            class="qi-cover-frame aspect-[2/3] w-full object-cover"
          />
          <div
            :if={!@cover_image_src}
            class="fallback-cover-grain qi-panel aspect-[2/3] w-full p-3 text-center"
            aria-label="Typographic cover fallback; no cover asset is available."
          >
            <div class="flex h-full flex-col items-center justify-center gap-2">
              <span class="font-serif text-2xl text-[var(--hiraeth-label)]">❧</span>
              <span class="font-serif text-sm leading-tight text-[var(--hiraeth-ink)]">{@book.title}</span>
            </div>
          </div>
        </div>
        <div class="min-w-0 space-y-2">
          <p class="qi-kicker text-[var(--hiraeth-thread)]">
            {@book.publisher || "Publisher unknown"}
          </p>
          <h3 class="font-serif text-2xl font-light leading-tight text-[var(--hiraeth-ink)]">
            {@book.title}
          </h3>
          <p :if={@authors} class="qi-muted text-sm">{@authors}</p>
        </div>
      </div>
      <CatalogComponents.metadata_table book={@book} />
      <div class="flex flex-wrap gap-3 border-t qi-divider pt-4">
        <.link navigate={~p"/books/#{@book.slug}"} class="qi-button qi-focus">Full record</.link>
        <.link
          :if={@book[:publisher_slug]}
          navigate={~p"/browse?publisher=#{@book.publisher_slug}"}
          class="qi-button-secondary qi-focus"
        >More from press</.link>
      </div>
    </div>
    """
  end

  defp role_names(contributors) when is_list(contributors) do
    names = contributors |> Enum.map(& &1[:name]) |> Enum.reject(&is_nil/1) |> Enum.join(", ")
    if names == "", do: nil, else: names
  end

  defp role_names(_contributors), do: nil

  defp reader_cover_src(nil), do: nil

  defp reader_cover_src(cover) do
    local_cover_url(cover[:public_url]) || local_cover_url(cover[:thumbnail_url])
  end

  defp local_cover_url(url) when is_binary(url) do
    if String.starts_with?(url, "/covers/cache/"), do: url
  end

  defp local_cover_url(_url), do: nil

  defp publisher_short(nil), do: "Unknown"

  defp publisher_short(publisher),
    do: publisher |> String.replace(" Books", "") |> String.replace(" Archive", "")

  defp description_excerpt(description, length) when is_binary(description),
    do: description |> String.trim() |> String.slice(0, length)

  defp query_context(""), do: nil
  defp query_context(query), do: "Current search: #{query}"
end
