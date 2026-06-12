defmodule HiraethWeb.CatalogComponents do
  @moduledoc """
  Components for rendering catalog listings, covers, metadata, and state views.
  """
  use HiraethWeb, :html

  @doc """
  Renders a provenance-safe typographic book cover fallback.
  """
  attr :book, :map, required: true
  attr :class, :string, default: ""

  def book_cover(assigns) do
    ~H"""
    <figure :if={@book[:cover]} id={"public-cover-#{@book.slug}"} class={[@class, "space-y-2"]}>
      <img
        src={@book.cover[:public_url] || @book.cover.source_url}
        alt={"Cover for #{@book.title}"}
        class="aspect-[2/3] w-full rounded-sm border border-[#E7E2D8] object-cover shadow-sm dark:border-[#2E2A27]"
      />
      <figcaption
        id={"cover-attribution-#{@book.slug}"}
        class="text-[10px] font-mono uppercase tracking-wider text-stone-600 dark:text-stone-400"
      >
        {@book.cover.attribution_text || @book.cover.provider}
      </figcaption>
    </figure>
    <div
      :if={!@book[:cover]}
      id={"missing-cover-#{@book.slug}"}
      class={[
        "aspect-[2/3] w-full rounded-sm border p-4 flex flex-col justify-between shadow-sm relative overflow-hidden transition-all duration-300 hover:-translate-y-1 hover:shadow-md select-none",
        @book[:cover_bg] ||
          "bg-[#FCFAF7] text-stone-900 border-[#E7E2D8] dark:bg-[#1C1917] dark:text-stone-100 dark:border-[#2E2A27]",
        @book[:cover_border] || "border-[#E7E2D8]",
        @class
      ]}
    >
      <div class="absolute inset-0 bg-[radial-gradient(circle_at_top_left,rgba(140,45,25,0.12),transparent_42%)]">
      </div>
      <div class="relative text-[9px] font-mono uppercase tracking-widest opacity-80 text-center">
        {@book.publisher || "Publisher unknown"}
      </div>
      <div class="relative flex flex-col items-center justify-center text-center flex-grow py-4 px-2">
        <span class="font-serif text-3xl text-current/20 mb-2">❧</span>
        <h3 class="font-serif text-lg md:text-xl font-medium leading-tight tracking-tight">
          {@book.title}
        </h3>
        <p :if={@book[:author]} class="font-sans text-xs italic mt-2 opacity-90">
          {@book.author}
        </p>
      </div>
      <div class="relative flex items-center justify-between text-[8px] font-mono uppercase tracking-wider opacity-70 border-t border-current/25 pt-2 gap-2">
        <span class="truncate">{List.first(@book[:series_titles] || []) || @book[:series] || "Edition"}</span>
        <span>{@book[:year] || "No date"}</span>
      </div>
      <p class="sr-only">Typographic cover fallback; no cover asset is available.</p>
    </div>
    """
  end

  attr :edition, :map, required: true
  attr :id_prefix, :string, default: "edition-card"
  attr :dom_id, :string, default: nil

  def edition_card(assigns) do
    ~H"""
    <article id={@dom_id || "#{@id_prefix}-#{@edition.slug}"} class="group space-y-3">
      <.link navigate={~p"/editions/#{@edition.slug}"} class="block">
        <.book_cover book={@edition} />
      </.link>
      <div class="space-y-1 rounded-sm bg-[#FCFAF7]/95 dark:bg-[#12110F]/90 p-2 ring-1 ring-[#E7E2D8]/80 dark:ring-[#2E2A27]">
        <h4 class="font-serif text-base font-bold tracking-tight !text-stone-950 dark:!text-stone-50 leading-snug">
          <.link
            navigate={~p"/editions/#{@edition.slug}"}
            class="hover:text-[#8C2D19] dark:hover:text-[#E05A47]"
          >
            {@edition.title}
          </.link>
        </h4>
        <p
          :if={@edition[:author]}
          class="font-sans text-sm font-medium text-stone-800 dark:text-stone-200 truncate"
        >
          {@edition.author}
        </p>
        <p class="font-mono text-[11px] font-semibold uppercase tracking-wider !text-stone-700 dark:!text-stone-300 truncate">
          {@edition.publisher || "Publisher unknown"}
        </p>
      </div>
    </article>
    """
  end

  attr :book, :map, required: true

  def metadata_table(assigns) do
    ~H"""
    <div class="space-y-4">
      <h3 class="font-serif text-lg font-medium border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-2">
        Bibliographic Data
      </h3>
      <dl class="divide-y divide-[#E7E2D8]/60 dark:divide-[#2E2A27]/60 text-sm">
        <.metadata_row label="Title" value={@book.title} serif />
        <.metadata_row :if={@book[:author]} label="Contributor" value={@book.author} />
        <.metadata_row :if={@book[:publisher]} label="Publisher" value={@book.publisher} />
        <.metadata_row
          :if={Enum.any?(@book[:series_titles] || [])}
          label="Series"
          value={Enum.join(@book.series_titles, ", ")}
        />
        <.metadata_row :if={@book[:format]} label="Format" value={@book.format} />
        <.metadata_row :if={@book[:isbn]} label="ISBN" value={@book.isbn} mono />
        <div id="publication-date" class="grid grid-cols-3 py-3">
          <dt class="font-mono text-xs uppercase tracking-wider text-stone-500 font-semibold">
            Publication Date
          </dt>
          <dd class="col-span-2 text-stone-800 dark:text-stone-200">
            {if @book[:published_on],
              do: Calendar.strftime(@book.published_on, "%Y-%m-%d"),
              else: "Publication date unknown"}
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :serif, :boolean, default: false
  attr :mono, :boolean, default: false

  def metadata_row(assigns) do
    ~H"""
    <div class="grid grid-cols-3 py-3">
      <dt class="font-mono text-xs uppercase tracking-wider text-stone-500 font-semibold">
        {@label}
      </dt>
      <dd class={[
        "col-span-2 text-stone-800 dark:text-stone-200",
        @serif && "font-serif text-stone-900 dark:text-stone-100 font-medium",
        @mono && "font-mono text-xs"
      ]}>
        {@value}
      </dd>
    </div>
    """
  end

  attr :source, :map, default: nil

  def provenance_badge(assigns) do
    ~H"""
    <div
      id="edition-provenance"
      class="rounded-sm border border-[#E7E2D8] dark:border-[#2E2A27] bg-[#F5F2EB] dark:bg-[#1C1917] p-4 text-xs text-stone-700 dark:text-stone-300 space-y-1"
    >
      <p class="font-mono uppercase tracking-wider text-stone-500">Source provenance</p>
      <%= if @source do %>
        <p>
          Provider:
          <span class="font-semibold text-stone-900 dark:text-stone-100">{@source.provider}</span>
        </p>
        <p :if={@source[:source_type]}>
          Source type:
          <span class="font-mono text-stone-900 dark:text-stone-100">{@source.source_type}</span>
        </p>
        <p :if={@source[:source_uri]}>
          Source record:
          <span class="font-mono text-stone-900 dark:text-stone-100">{@source.source_uri}</span>
        </p>
        <p :if={@source[:imported_at]}>
          Imported:
          <span class="font-mono text-stone-900 dark:text-stone-100">{Calendar.strftime(
            @source.imported_at,
            "%Y-%m-%d %H:%M:%S UTC"
          )}</span>
        </p>
        <p :if={@source[:license_note]}>{@source.license_note}</p>
      <% else %>
        <p>No source record has been attached to this edition yet.</p>
      <% end %>
    </div>
    """
  end

  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :base_path, :string, required: true
  attr :query, :string, default: ""

  def pagination(assigns) do
    assigns = assign(assigns, :has_previous, assigns.page > 1)
    assigns = assign(assigns, :has_next, assigns.page < assigns.total_pages)

    ~H"""
    <nav
      id="catalog-pagination"
      class="flex items-center justify-between border-t border-[#E7E2D8] dark:border-[#2E2A27] pt-4 text-xs font-mono text-stone-500"
    >
      <.link
        :if={@has_previous}
        navigate={page_path(@base_path, @page - 1, @query)}
        id="catalog-prev-page"
        class="text-[#8C2D19] dark:text-[#E05A47] hover:underline"
      >
        ← Previous
      </.link>
      <span :if={!@has_previous} class="text-stone-500 dark:text-stone-500">← Previous</span>
      <span id="catalog-page-count">Page {@page} of {@total_pages}</span>
      <.link
        :if={@has_next}
        navigate={page_path(@base_path, @page + 1, @query)}
        id="catalog-next-page"
        class="text-[#8C2D19] dark:text-[#E05A47] hover:underline"
      >
        Next →
      </.link>
      <span :if={!@has_next} class="text-stone-500 dark:text-stone-500">Next →</span>
    </nav>
    """
  end

  attr :id, :string, default: "catalog-loading"
  attr :label, :string, default: "Loading catalog records"

  def loading_skeleton(assigns) do
    ~H"""
    <div id={@id} class="animate-pulse space-y-6" role="status" aria-busy="true">
      <span class="sr-only">{@label}</span>
      <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-6">
        <div :for={_i <- 1..4} class="space-y-3">
          <div class="aspect-[2/3] w-full bg-[#E7E2D8] dark:bg-[#2E2A27] rounded-sm"></div>
          <div class="h-4 bg-[#E7E2D8] dark:bg-[#2E2A27] rounded w-3/4"></div>
          <div class="h-3 bg-[#E7E2D8] dark:bg-[#2E2A27] rounded w-1/2"></div>
        </div>
      </div>
    </div>
    """
  end

  attr :message, :string, default: "No volumes found matching the current criteria."
  attr :id, :string, default: "catalog-empty"
  attr :title, :string, default: "Nothing on this shelf yet"
  attr :eyebrow, :string, default: "Archive note"
  attr :context, :string, default: nil
  attr :action_label, :string, default: nil
  attr :action_path, :string, default: nil

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class="border border-dashed border-[#E7E2D8] dark:border-[#2E2A27] bg-[#FCFAF7]/80 dark:bg-[#12110F]/70 p-10 text-center max-w-lg mx-auto rounded-sm space-y-4 my-8"
    >
      <div class="flex justify-center">
        <span class="font-serif text-3xl text-stone-300 dark:text-stone-700">❧</span>
      </div>
      <p class="text-[10px] text-stone-500 font-mono uppercase tracking-[0.2em]">{@eyebrow}</p>
      <h2 class="font-serif text-2xl font-medium text-stone-900 dark:text-stone-100">
        {@title}
      </h2>
      <p class="font-serif text-stone-700 dark:text-stone-300">
        {@message}
      </p>
      <p
        :if={@context}
        class="rounded-sm bg-[#F5F2EB] px-3 py-2 text-xs font-mono text-stone-600 dark:bg-[#1C1917] dark:text-stone-400"
      >
        {@context}
      </p>
      <.link
        :if={@action_label && @action_path}
        navigate={@action_path}
        class="inline-flex rounded-sm border border-[#8C2D19] px-3 py-2 text-xs font-bold uppercase tracking-wider text-[#8C2D19] hover:bg-[#8C2D19] hover:text-white"
      >
        {@action_label}
      </.link>
      <p class="text-xs text-stone-600 dark:text-stone-400 font-mono">HIRAETH EDITORIAL ARCHIVE</p>
    </div>
    """
  end

  attr :id, :string, default: "auth-required"
  attr :return_to, :string, default: "/admin"

  def auth_required_state(assigns) do
    ~H"""
    <.empty_state
      id={@id}
      eyebrow="Restricted shelf"
      title="Sign in to continue cataloging"
      message="Administrative catalog tools require an authenticated curator account."
      action_label="Sign in"
      action_path={"/sign-in?return_to=#{URI.encode(@return_to)}"}
    />
    """
  end

  attr :message, :string, required: true
  attr :id, :string, default: "catalog-error"
  attr :title, :string, default: "Cataloging Error"

  def error_block(assigns) do
    ~H"""
    <div
      id={@id}
      class="bg-[#FFF5F5] dark:bg-[#201010] border-l-4 border-red-800 dark:border-red-600 p-4 rounded-sm"
    >
      <div class="flex gap-3">
        <div class="text-red-800 dark:text-red-400 shrink-0">
          <.icon name="hero-exclamation-triangle-micro" class="size-5" />
        </div>
        <div>
          <h3 class="text-sm font-semibold text-red-800 dark:text-red-400">{@title}</h3>
          <p class="text-xs text-red-700 dark:text-red-300 mt-1">{@message}</p>
        </div>
      </div>
    </div>
    """
  end

  defp page_path(base_path, page, ""), do: "#{base_path}?page=#{page}"
  defp page_path(base_path, page, query), do: "#{base_path}?page=#{page}&q=#{URI.encode(query)}"
end
