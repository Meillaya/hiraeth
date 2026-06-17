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
  attr :loading, :string, default: "lazy"
  attr :fetchpriority, :string, default: "auto"
  attr :variant, :string, default: "card"

  def book_cover(assigns) do
    ~H"""
    <figure :if={@book[:cover]} id={"public-cover-#{@book.slug}"} class={[@class, "space-y-2"]}>
      <img
        src={cover_src(@book.cover, @variant)}
        alt={"Cover for #{@book.title}"}
        loading={@loading}
        decoding="async"
        fetchpriority={@fetchpriority}
        width="400"
        height="600"
        class="qi-cover-frame aspect-[2/3] w-full object-cover transition duration-300 group-hover:-translate-y-1 group-hover:shadow-[0_28px_70px_-34px_rgba(28,25,23,0.9)]"
      />
      <figcaption
        id={"cover-attribution-#{@book.slug}"}
        class="qi-label text-[10px]"
      >
        {@book.cover.attribution_text || @book.cover.provider}
      </figcaption>
    </figure>
    <div
      :if={!@book[:cover]}
      id={"missing-cover-#{@book.slug}"}
      class={[
        "fallback-cover-grain qi-panel aspect-[2/3] w-full p-4 flex flex-col justify-between shadow-sm relative overflow-hidden transition-all duration-300 hover:-translate-y-1 hover:shadow-md select-none",
        @book[:cover_bg] || "bg-[var(--hiraeth-paper)] text-[var(--hiraeth-ink)]",
        @book[:cover_border] || "border-[var(--hiraeth-line)]",
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
        <p :if={role_names(@book[:authors])} class="font-sans text-xs italic mt-2 opacity-90">
          by {role_names(@book[:authors])}
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

  defp cover_src(cover, "hero"), do: cover[:public_url] || cover.source_url

  defp cover_src(cover, _variant),
    do: cover[:thumbnail_url] || cover[:public_url] || cover.source_url

  attr :edition, :map, required: true
  attr :id_prefix, :string, default: "edition-card"
  attr :dom_id, :string, default: nil

  def edition_card(assigns) do
    ~H"""
    <article id={@dom_id || "#{@id_prefix}-#{@edition.slug}"} class="group space-y-3">
      <.link
        navigate={~p"/books/#{@edition.slug}"}
        class="qi-focus block rounded-sm"
      >
        <.book_cover book={@edition} />
      </.link>
      <div class="qi-card space-y-2 p-3 ring-1 ring-[var(--hiraeth-line)]/80 transition duration-300 group-hover:-translate-y-0.5 group-hover:ring-[var(--hiraeth-thread)]/35 group-hover:shadow-[0_18px_45px_-32px_rgba(28,25,23,0.8)]">
        <h4 class="font-serif text-base font-bold tracking-tight !text-[var(--hiraeth-ink)] leading-snug">
          <.link
            navigate={~p"/books/#{@edition.slug}"}
            class="qi-focus rounded-sm hover:text-[var(--hiraeth-thread)]"
          >
            {@edition.title}
          </.link>
        </h4>
        <div class="space-y-0.5 text-sm font-medium text-[var(--hiraeth-ink)]">
          <p :if={role_names(@edition[:authors])} class="truncate">
            by {role_names(@edition[:authors])}
          </p>
          <p
            :if={role_names(@edition[:translators])}
            class="qi-muted truncate"
          >
            translated by {role_names(@edition[:translators])}
          </p>
        </div>
        <p class="qi-label truncate text-[11px] font-semibold">
          {@edition.publisher || "Publisher unknown"}
        </p>
        <p
          :if={@edition[:description]}
          class="qi-muted line-clamp-3 border-l border-[var(--hiraeth-line-strong)] pl-2 font-serif text-xs leading-relaxed"
        >
          {description_excerpt(@edition.description)}
        </p>
        <div
          :if={Enum.any?(@edition[:formats] || [])}
          class="qi-muted flex flex-wrap gap-1.5 pt-1 font-mono text-[9px] leading-relaxed"
        >
          <span
            :for={format <- @edition.formats}
            class="rounded-full border border-[var(--hiraeth-line-strong)] bg-[var(--hiraeth-wash)]/70 px-2 py-0.5 uppercase tracking-wider"
          >
            {format.format} · {Enum.join(format.identifiers, ", ")}
          </span>
        </div>
      </div>
    </article>
    """
  end

  defp description_excerpt(description) when is_binary(description) do
    description
    |> String.trim()
    |> String.slice(0, 180)
  end

  defp description_excerpt(_description), do: nil

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

  attr :book, :map, required: true

  def metadata_table(assigns) do
    ~H"""
    <div class="space-y-4">
      <h3 class="border-b qi-divider pb-2 font-serif text-lg font-medium text-[var(--hiraeth-ink)]">
        Bibliographic Data
      </h3>
      <dl class="divide-y divide-[var(--hiraeth-line)]/60 text-sm">
        <.metadata_row label="Title" value={@book.title} serif />
        <.metadata_row
          :if={present?(@book[:original_title])}
          id="book-original-title"
          label="Original title"
          value={@book.original_title}
          serif
        />
        <.metadata_row
          :if={present?(@book[:original_language_code])}
          id="book-original-language"
          label="Original language"
          value={@book.original_language_code}
          mono
        />
        <.metadata_row
          :if={role_names(@book[:authors])}
          label="Author"
          value={role_names(@book[:authors])}
        />
        <.metadata_row
          :if={role_names(@book[:translators])}
          label="Translator"
          value={role_names(@book[:translators])}
        />
        <.metadata_row :if={@book[:publisher]} label="Publisher" value={@book.publisher} />
        <.metadata_row
          :if={Enum.any?(@book[:series_titles] || [])}
          label="Series"
          value={Enum.join(@book.series_titles, ", ")}
        />
        <.metadata_row :if={@book[:format]} label="Format" value={@book.format} />
        <.metadata_row
          :if={subject_text(@book[:subjects])}
          id="book-subjects"
          label="Subjects"
          value={subject_text(@book[:subjects])}
        />
        <.metadata_row :if={@book[:isbn]} label="ISBN" value={@book.isbn} mono />
        <div id="publication-date" class="grid grid-cols-3 py-3">
          <dt class="qi-label text-xs font-bold">
            Publication Date
          </dt>
          <dd class="col-span-2 font-medium text-[var(--hiraeth-ink)]">
            {if @book[:published_on],
              do: Calendar.strftime(@book.published_on, "%Y-%m-%d"),
              else: "Publication date unknown"}
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :serif, :boolean, default: false
  attr :mono, :boolean, default: false

  def metadata_row(assigns) do
    ~H"""
    <div id={@id} class="grid grid-cols-3 py-3">
      <dt class="qi-label text-xs font-bold">
        {@label}
      </dt>
      <dd class={[
        "col-span-2 break-words font-medium text-[var(--hiraeth-ink)]",
        @serif && "font-serif font-medium",
        @mono && "font-mono text-xs"
      ]}>
        {@value}
      </dd>
    </div>
    """
  end

  defp present?(value), do: value not in [nil, "", []]

  defp subject_text(subjects) when is_list(subjects) do
    subjects
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp subject_text(_subjects), do: nil

  defp field_source_notes(nil), do: []
  defp field_source_notes(field_sources) when field_sources == %{}, do: []

  defp field_source_notes(field_sources) when is_map(field_sources) do
    field_sources
    |> Enum.flat_map(fn {field, source} ->
      rights_basis = source["rights_basis"] || source[:rights_basis]
      provider = source["provider"] || source[:provider]

      cond do
        present?(rights_basis) and present?(provider) ->
          ["#{humanize_field(field)} — #{rights_basis} via #{provider}"]

        present?(rights_basis) ->
          ["#{humanize_field(field)} — #{rights_basis}"]

        true ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp field_source_notes(_field_sources), do: []

  defp humanize_field(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
  end

  attr :source, :map, default: nil

  def provenance_badge(assigns) do
    ~H"""
    <div
      id="edition-provenance"
      data-provenance-motif="source-thread"
      class="provenance-thread qi-panel-soft space-y-1 break-words py-4 pl-6 pr-4 text-xs text-[var(--hiraeth-ink)] shadow-[inset_0_1px_0_rgba(255,255,255,0.55)]"
    >
      <p class="qi-label">
        Source provenance
      </p>
      <%= if @source do %>
        <p>
          Provider: <span class="font-semibold text-[var(--hiraeth-ink)]">{@source.provider}</span>
        </p>
        <p :if={@source[:source_type]}>
          Source type: <span class="font-mono text-[var(--hiraeth-ink)]">{@source.source_type}</span>
        </p>
        <p :if={@source[:source_uri]}>
          Source record:
          <span class="break-all font-mono text-[var(--hiraeth-ink)]">{@source.source_uri}</span>
        </p>
        <p :if={@source[:imported_at]}>
          Imported:
          <span class="font-mono text-[var(--hiraeth-ink)]">{Calendar.strftime(
            @source.imported_at,
            "%Y-%m-%d %H:%M:%S UTC"
          )}</span>
        </p>
        <div
          :if={field_source_notes(@source[:field_sources]) != []}
          id="edition-field-provenance"
          class="pt-2"
        >
          <p class="qi-label text-[10px]">
            Field-level provenance
          </p>
          <p class="qi-muted mt-1">
            {Enum.join(field_source_notes(@source.field_sources), "; ")}
          </p>
        </div>
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
  attr :params, :map, default: %{}

  def pagination(assigns) do
    assigns = assign(assigns, :has_previous, assigns.page > 1)
    assigns = assign(assigns, :has_next, assigns.page < assigns.total_pages)

    ~H"""
    <nav
      id="catalog-pagination"
      class="qi-muted flex items-center justify-between border-t qi-divider pt-4 text-xs font-mono"
    >
      <.link
        :if={@has_previous}
        navigate={page_path(@base_path, @page - 1, @query, @params)}
        id="catalog-prev-page"
        class="qi-action-link rounded-sm hover:underline"
      >
        ← Previous
      </.link>
      <span :if={!@has_previous} class="qi-muted opacity-70">← Previous</span>
      <span id="catalog-page-count">Page {@page} of {@total_pages}</span>
      <.link
        :if={@has_next}
        navigate={page_path(@base_path, @page + 1, @query, @params)}
        id="catalog-next-page"
        class="qi-action-link rounded-sm hover:underline"
      >
        Next →
      </.link>
      <span :if={!@has_next} class="qi-muted opacity-70">Next →</span>
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
          <div class="aspect-[2/3] w-full rounded-sm bg-[var(--hiraeth-line)]"></div>
          <div class="h-4 w-3/4 rounded bg-[var(--hiraeth-line)]"></div>
          <div class="h-3 w-1/2 rounded bg-[var(--hiraeth-line)]"></div>
        </div>
      </div>
    </div>
    """
  end

  attr :message, :string, default: "No books found matching the current criteria."
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
      class="qi-empty mx-auto my-8 max-w-lg space-y-4 p-10 text-center shadow-[inset_0_0_0_1px_rgba(255,255,255,0.45)]"
    >
      <div class="flex justify-center">
        <span class="font-serif text-3xl text-stone-300 dark:text-stone-700">❧</span>
      </div>
      <p class="qi-label text-[10px]">{@eyebrow}</p>
      <h2 class="font-serif text-2xl font-medium text-[var(--hiraeth-ink)]">
        {@title}
      </h2>
      <p class="qi-muted font-serif">
        {@message}
      </p>
      <p
        :if={@context}
        class="qi-panel-soft qi-muted px-3 py-2 text-xs font-mono"
      >
        {@context}
      </p>
      <.link
        :if={@action_label && @action_path}
        navigate={@action_path}
        class="qi-button-secondary qi-focus"
      >
        {@action_label}
      </.link>
      <p class="qi-label text-xs">HIRAETH EDITORIAL ARCHIVE</p>
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

  defp page_path(base_path, page, _query, params) when map_size(params) > 0 do
    params
    |> Map.put("page", page)
    |> drop_blank_params()
    |> then(&(base_path <> "?" <> URI.encode_query(&1)))
  end

  defp page_path(base_path, page, "", _params), do: "#{base_path}?page=#{page}"

  defp page_path(base_path, page, query, _params),
    do: "#{base_path}?page=#{page}&q=#{URI.encode(query)}"

  defp drop_blank_params(params) do
    params
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
