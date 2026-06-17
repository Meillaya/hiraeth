defmodule HiraethWeb.BrowseLive.Components do
  use HiraethWeb, :html

  alias HiraethWeb.CatalogComponents

  def browse_shell(assigns) do
    ~H"""
    <main id="browse-shell" class="archive-wash pb-8">
      <div class="grid grid-cols-1 gap-8 lg:grid-cols-[14.5rem_minmax(0,1fr)_21rem] lg:items-start lg:gap-10">
        <.filter_rail form={@form} filter_form={@filter_form} query={@query} />
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
      <.filter_form form={@filter_form} query={@query} />
      <div class="qi-panel-soft space-y-2 p-4">
        <p class="qi-kicker text-[var(--hiraeth-thread)]">Known fields only</p>
        <p class="font-serif text-sm leading-relaxed text-[var(--hiraeth-muted)]">
          Dates, translators, descriptions, and cover assets appear only when a source supplies them. Unsourced covers fall back to type.
        </p>
      </div>
    </aside>
    """
  end

  defp filter_form(assigns) do
    ~H"""
    <.form for={@form} id="catalog-filter-form" phx-change="filter" class="space-y-4">
      <input type="hidden" name="filters[q]" value={@query} />
      <.text_filter form={@form} field={:publisher} label="Publisher" placeholder="deep-vellum" />
      <.text_filter form={@form} field={:contributor} label="Contributor" placeholder="david-bowles" />
      <div class="grid grid-cols-2 gap-3 lg:grid-cols-1 xl:grid-cols-2">
        <.select_filter form={@form} field={:role} label="Role" options={role_options()} />
        <.text_filter form={@form} field={:format} label="Format" placeholder="paperback" />
      </div>
      <div class="grid grid-cols-2 gap-3 lg:grid-cols-1 xl:grid-cols-2">
        <.text_filter form={@form} field={:language} label="Language" placeholder="eng" />
        <.text_filter form={@form} field={:year} label="Year" placeholder="2026" />
      </div>
      <.text_filter form={@form} field={:subject} label="Subject" placeholder="translation" />
      <.text_filter form={@form} field={:series} label="Series" placeholder="series slug" />
      <.select_filter form={@form} field={:sort} label="Sort" options={sort_options()} />
    </.form>
    """
  end

  defp text_filter(assigns) do
    ~H"""
    <.input field={@form[@field]} type="text" label={@label} placeholder={@placeholder} />
    """
  end

  defp select_filter(assigns) do
    ~H"""
    <.input field={@form[@field]} type="select" label={@label} options={@options} />
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
      <div class="qi-card space-y-2 p-3 ring-1 ring-[var(--hiraeth-line)]/80 transition duration-300 group-hover:-translate-y-0.5 group-hover:ring-[var(--hiraeth-thread)]/35">
        <h4 class="font-serif text-base font-bold leading-snug tracking-tight text-[var(--hiraeth-ink)]">
          <.link
            navigate={~p"/books/#{@book.slug}"}
            class="qi-focus rounded-sm hover:text-[var(--hiraeth-thread)]"
          >{@book.title}</.link>
        </h4>
        <div class="space-y-0.5 text-sm font-medium text-[var(--hiraeth-ink)]">
          <p :if={role_names(@book[:authors])} class="truncate">by {role_names(@book.authors)}</p>
          <p :if={role_names(@book[:translators])} class="qi-muted truncate">
            translated by {role_names(@book.translators)}
          </p>
        </div>
        <p class="qi-label truncate text-[11px] font-semibold">
          {@book.publisher || "Publisher unknown"}
        </p>
        <p
          :if={@book[:description]}
          class="qi-muted line-clamp-3 border-l border-[var(--hiraeth-line-strong)] pl-2 font-serif text-xs leading-relaxed"
        >
          {description_excerpt(@book.description, 180)}
        </p>
        <div
          :if={Enum.any?(@book[:formats] || [])}
          class="qi-muted flex flex-wrap gap-1.5 pt-1 font-mono text-[9px] leading-relaxed"
        >
          <span
            :for={format <- @book.formats}
            class="rounded-sm border border-[var(--hiraeth-line-strong)] bg-[var(--hiraeth-wash)]/70 px-2 py-0.5 uppercase tracking-wider"
          >
            {format.format} · {Enum.join(format.identifiers, ", ")}
          </span>
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
    assigns = assign(assigns, :authors, role_names(assigns.book[:authors]))

    ~H"""
    <div class="qi-panel space-y-6 p-4 shadow-[var(--hiraeth-shadow)]">
      <div class="flex items-start gap-4">
        <div class="w-24 flex-none">
          <img
            :if={@book[:cover]}
            src={reader_cover_src(@book.cover)}
            alt={"Cover for #{@book.title}"}
            loading="lazy"
            decoding="async"
            width="160"
            height="240"
            class="qi-cover-frame aspect-[2/3] w-full object-cover"
          />
          <div
            :if={!@book[:cover]}
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
      <CatalogComponents.provenance_badge source={@book.source} />
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

  defp role_options, do: [{"Any", ""}, {"Author", "author"}, {"Translator", "translator"}]

  defp sort_options,
    do: [
      {"Title", "title"},
      {"Newest", "newest"},
      {"Author", "author"},
      {"Recently added", "recently_added"}
    ]

  defp role_names(contributors) when is_list(contributors) do
    names = contributors |> Enum.map(& &1[:name]) |> Enum.reject(&is_nil/1) |> Enum.join(", ")
    if names == "", do: nil, else: names
  end

  defp role_names(_contributors), do: nil

  defp reader_cover_src(cover),
    do: cover[:public_url] || cover[:thumbnail_url] || cover[:source_url]

  defp publisher_short(nil), do: "Unknown"

  defp publisher_short(publisher),
    do: publisher |> String.replace(" Books", "") |> String.replace(" Archive", "")

  defp description_excerpt(description, length) when is_binary(description),
    do: description |> String.trim() |> String.slice(0, length)

  defp query_context(""), do: nil
  defp query_context(query), do: "Current search: #{query}"
end
