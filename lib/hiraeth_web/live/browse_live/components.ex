defmodule HiraethWeb.BrowseLive.Components do
  use HiraethWeb, :html

  alias HiraethWeb.CatalogComponents

  def browse_shell(assigns) do
    ~H"""
    <div id="browse-shell" class="space-y-10 pb-10">
      <.browse_masthead form={@form} pagination={@pagination} query={@query} />
      <.filter_rail
        filter_form={@filter_form}
        query={@query}
        publisher_facets={@publisher_facets}
        filters={@filters}
      />
      <div class="grid grid-cols-1 gap-10 xl:grid-cols-[minmax(0,1fr)_18rem] xl:items-start">
        <.catalog_index pagination={@pagination} streams={@streams} query={@query} filters={@filters} />
        <.reader_rail book={@selected_book} query={@query} />
      </div>
    </div>
    """
  end

  defp browse_masthead(assigns) do
    ~H"""
    <header
      id="browse-masthead"
      class="grid gap-8 border-b qi-divider pb-8 md:grid-cols-[minmax(0,1fr)_minmax(18rem,25rem)] md:items-end"
    >
      <div class="max-w-3xl">
        <p class="qi-kicker text-[var(--hiraeth-thread)]">The catalog</p>
        <h1 class="mt-3 font-serif text-5xl font-light leading-none tracking-tight text-[var(--hiraeth-ink)] sm:text-6xl">
          Browse
        </h1>
        <p class="qi-muted mt-5 max-w-2xl font-serif text-lg italic leading-relaxed">
          Move through the archive by press, title, contributor, or ISBN.
        </p>
      </div>
      <.form
        for={@form}
        id="browse-search-form"
        phx-change="search"
        class="relative"
      >
        <.input
          field={@form[:query]}
          type="text"
          label="Search catalog"
          placeholder="Title, contributor, ISBN…"
          phx-debounce="250"
        />
        <p class="sr-only">
          {if @query == "", do: "Browsing catalog.", else: "Current search: #{@query}."}
          {visible_page_text(@pagination)}
        </p>
      </.form>
    </header>
    """
  end

  defp filter_rail(assigns) do
    ~H"""
    <aside id="catalog-filters" class="space-y-4">
      <.form for={@filter_form} id="catalog-filter-form" phx-change="filter" class="sr-only">
        <input type="hidden" name="filters[q]" value={@query} />
        <input
          type="text"
          class="sr-only"
          tabindex="-1"
          aria-label="Publisher filter"
          name="filters[publisher]"
          value={@filter_form[:publisher].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          tabindex="-1"
          aria-label="Contributor filter"
          name="filters[contributor]"
          value={@filter_form[:contributor].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          tabindex="-1"
          aria-label="Role filter"
          name="filters[role]"
          value={@filter_form[:role].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          tabindex="-1"
          aria-label="Format filter"
          name="filters[format]"
          value={@filter_form[:format].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          tabindex="-1"
          aria-label="Language filter"
          name="filters[language]"
          value={@filter_form[:language].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          tabindex="-1"
          aria-label="Year filter"
          name="filters[year]"
          value={@filter_form[:year].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          tabindex="-1"
          aria-label="Subject filter"
          name="filters[subject]"
          value={@filter_form[:subject].value || ""}
        />
        <input
          type="text"
          class="sr-only"
          tabindex="-1"
          aria-label="Series filter"
          name="filters[series]"
          value={@filter_form[:series].value || ""}
        />
        <select name="filters[sort]" aria-label="Sort catalog" class="sr-only" tabindex="-1">
          <option value="newest" selected={@filter_form[:sort].value in [nil, "", "newest"]}>
            Publication date, newest first
          </option>
        </select>
      </.form>
      <div class="space-y-3">
        <div class="flex items-center justify-between gap-4">
          <h2 class="qi-label">Press shelves</h2>
          <.link navigate={~p"/browse"} class={press_filter_class(@filters["publisher"] in [nil, ""])}>
            All presses
          </.link>
        </div>
        <div class="flex gap-2 overflow-x-auto pb-2">
          <.link
            :for={publisher <- @publisher_facets}
            navigate={~p"/browse?publisher=#{publisher.slug}"}
            class={press_filter_class(@filters["publisher"] == publisher.slug)}
          >
            <span class="truncate">{publisher.name}</span>
          </.link>
        </div>
      </div>
      <div class="flex flex-wrap gap-2">
        <p class="sr-only">Format filters</p>
        <div class="flex flex-wrap gap-2 text-[13px] text-[var(--hiraeth-ink)]">
          <.link
            navigate={~p"/browse?format=paperback"}
            class={press_filter_class(@filters["format"] == "paperback")}
          >
            Paperback
          </.link>
          <.link
            navigate={~p"/browse?format=hardcover"}
            class={press_filter_class(@filters["format"] == "hardcover")}
          >
            Hardcover
          </.link>
          <.link
            navigate={~p"/browse?format=ebook"}
            class={press_filter_class(@filters["format"] == "ebook")}
          >
            Ebook
          </.link>
        </div>
      </div>
    </aside>
    """
  end

  defp catalog_index(assigns) do
    ~H"""
    <section id="catalog-index" class="min-w-0 space-y-6">
      <div class="flex items-baseline justify-between gap-4">
        <h2 class="font-serif text-2xl font-normal text-[var(--hiraeth-ink)]">Shelf</h2>
        <span class="font-mono text-xs text-[var(--hiraeth-muted)]">
          {visible_page_text(@pagination)}
        </span>
      </div>
      <%= if @pagination.total_count == 0 do %>
        <div id="browse-empty">
          <CatalogComponents.empty_state
            id="catalog-empty"
            title="No catalog entries match"
            message="Adjust the search or choose another shelf."
            context={query_context(@query)}
            action_label="Clear search"
            action_path="/browse"
          />
        </div>
      <% else %>
        <div
          id="catalog-grid"
          phx-update="stream"
          class="grid grid-cols-2 gap-x-6 gap-y-10 md:grid-cols-3 lg:grid-cols-4"
        >
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
        <p :if={@book[:publisher]} class="qi-label truncate text-[10px]">
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
    <aside id="book-reader" class="qi-panel-soft space-y-6 p-5 xl:sticky xl:top-24">
      <h2 class="font-serif text-xl font-normal text-[var(--hiraeth-ink)]">Selected book</h2>
      <%= if @book do %>
        <.selected_reader book={@book} />
      <% else %>
        <CatalogComponents.empty_state
          id="book-reader-empty"
          title="No book selected"
          message="Choose a cover from the shelf to preview it here."
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
              <span class="h-px w-10 bg-[var(--hiraeth-line-strong)]"></span>
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
      <p
        :if={@book[:description]}
        class="qi-muted border-l border-[var(--hiraeth-line-strong)] pl-4 font-serif text-sm italic leading-relaxed"
      >
        {description_excerpt(@book.description, 160)}
      </p>
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

  defp description_excerpt(description, length) when is_binary(description),
    do: description |> String.trim() |> String.slice(0, length)

  defp query_context(""), do: nil
  defp query_context(query), do: "Current search: #{query}"

  defp visible_page_text(%{page: page, total_pages: total_pages}) do
    "Page #{page} of #{total_pages}"
  end

  defp press_filter_class(true) do
    "qi-focus shrink-0 border border-[var(--hiraeth-ink)] bg-[var(--hiraeth-ink)] px-3 py-2 font-sans text-xs font-semibold text-[var(--hiraeth-paper)] transition duration-200"
  end

  defp press_filter_class(false) do
    "qi-focus shrink-0 border border-[var(--hiraeth-line)] bg-[var(--hiraeth-paper)] px-3 py-2 font-sans text-xs font-medium text-[var(--hiraeth-muted)] transition duration-200 hover:border-[var(--hiraeth-thread)] hover:text-[var(--hiraeth-thread)]"
  end
end
