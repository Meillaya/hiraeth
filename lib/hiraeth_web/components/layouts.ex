defmodule HiraethWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HiraethWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :current_user, :map, default: nil, doc: "the currently authenticated user"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-[#E7E2D8] dark:border-[#2E2A27] bg-[#FCFAF7]/95 dark:bg-[#12110F]/95 backdrop-blur sticky top-0 z-40 transition-colors duration-300">
      <div class="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
        <div class="flex h-16 items-center justify-between">
          <div class="flex items-center gap-8">
            <a href="/" class="flex items-center gap-2">
              <span class="font-serif text-2xl font-semibold tracking-tight text-[#8C2D19] dark:text-[#E05A47]">Hiraeth</span>
              <span class="text-[10px] font-mono uppercase tracking-widest text-stone-600 dark:text-stone-400 border border-stone-200 dark:border-stone-800 px-1.5 py-0.5 rounded">Archive</span>
            </a>
            <nav
              class="hidden md:flex items-center gap-6 text-sm font-medium text-stone-700 dark:text-stone-200"
              aria-label="Primary navigation"
            >
              <a
                href="/browse"
                class="hover:text-stone-900 dark:hover:text-stone-100 transition-colors"
              >Browse</a>
              <a
                href="/search"
                class="hover:text-stone-900 dark:hover:text-stone-100 transition-colors"
              >Search</a>
              <a
                href="/publishers"
                class="hover:text-stone-900 dark:hover:text-stone-100 transition-colors"
              >Publishers</a>
              <a
                href="/series"
                class="hover:text-stone-900 dark:hover:text-stone-100 transition-colors"
              >Series</a>
            </nav>
          </div>

          <div class="hidden min-w-0 items-center gap-4 sm:flex">
            <nav class="flex min-w-0 items-center gap-4">
              <%= if @current_user do %>
                <div class="hidden min-w-0 items-center gap-2 text-xs font-mono text-stone-500 xl:flex">
                  <span class="max-w-44 truncate" title={@current_user.email}>
                    {@current_user.email}
                  </span>
                  <%= if @current_user.admin? do %>
                    <span class="bg-[#8C2D19]/10 text-[#8C2D19] dark:bg-[#E05A47]/10 dark:text-[#E05A47] text-[10px] px-1.5 py-0.5 rounded font-sans uppercase font-bold tracking-wider">Admin</span>
                  <% end %>
                </div>
                <a
                  href="/admin"
                  class="whitespace-nowrap text-sm font-medium text-stone-700 dark:text-stone-200 hover:text-stone-900 dark:hover:text-stone-100 transition-colors"
                >Dashboard</a>
                <.link
                  href={~p"/sign-out"}
                  class="whitespace-nowrap text-sm font-medium text-[#8C2D19] dark:text-[#E05A47] hover:underline"
                  method="delete"
                >
                  Sign out
                </.link>
              <% else %>
                <a
                  href="/sign-in"
                  class="text-sm font-medium text-stone-700 dark:text-stone-200 hover:text-stone-900 dark:hover:text-stone-100 transition-colors"
                >Sign in</a>
              <% end %>
              <div class="border-l border-[#E7E2D8] dark:border-[#2E2A27] pl-4">
                <.theme_toggle />
              </div>
            </nav>
          </div>
        </div>
      </div>
    </header>

    <nav
      class="md:hidden border-b border-[#E7E2D8] dark:border-[#2E2A27] bg-[#FCFAF7]/95 dark:bg-[#12110F]/95 px-4 py-3"
      aria-label="Mobile primary navigation"
    >
      <div class="mx-auto flex max-w-6xl items-center gap-4 overflow-x-auto text-sm font-medium text-stone-700 dark:text-stone-200">
        <a href="/browse" class="shrink-0 hover:text-stone-900 dark:hover:text-stone-100">Browse</a>
        <a href="/search" class="shrink-0 hover:text-stone-900 dark:hover:text-stone-100">Search</a>
        <a href="/publishers" class="shrink-0 hover:text-stone-900 dark:hover:text-stone-100">Publishers</a>
        <a href="/series" class="shrink-0 hover:text-stone-900 dark:hover:text-stone-100">Series</a>
        <%= if @current_user do %>
          <a href="/admin" class="shrink-0 hover:text-stone-900 dark:hover:text-stone-100">
            Dashboard
          </a>
          <.link
            href={~p"/sign-out"}
            class="shrink-0 text-[#8C2D19] dark:text-[#E05A47] hover:underline"
            method="delete"
          >
            Sign out
          </.link>
        <% else %>
          <a href="/sign-in" class="shrink-0 hover:text-stone-900 dark:hover:text-stone-100">
            Sign in
          </a>
        <% end %>
      </div>
    </nav>

    <main class="flex-grow py-12 px-4 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-6xl">
        {render_slot(@inner_block)}
      </div>
    </main>

    <footer class="border-t border-[#E7E2D8] dark:border-[#2E2A27] py-8 mt-auto bg-[#F5F2EB]/50 dark:bg-[#1C1917]/50 text-stone-700 dark:text-stone-300 text-xs">
      <div class="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8 flex flex-col md:flex-row justify-between items-center gap-4">
        <p class="font-serif">Hiraeth &mdash; A quiet editorial archive of independent publishers.</p>
        <p class="font-mono">© {DateTime.utc_now().year} Hiraeth Project. All rights reserved.</p>
      </div>
    </footer>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex w-24 flex-row items-center rounded-full border border-[#E7E2D8] bg-[#F5F2EB] p-0.5 dark:border-[#2E2A27] dark:bg-[#1C1917]">
      <div class="absolute left-0.5 top-0.5 h-[calc(100%-0.25rem)] w-1/3 rounded-full border border-[#E7E2D8] bg-[#FCFAF7] shadow-sm transition-[left] dark:border-[#2E2A27] dark:bg-[#12110F] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-[calc(66.666%-0.125rem)] [[data-theme-source=system]_&]:!left-0.5" />

      <button
        class="relative z-10 flex w-1/3 cursor-pointer justify-center p-2 text-stone-600 transition hover:text-stone-950 dark:text-stone-300 dark:hover:text-stone-50"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
        title="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative z-10 flex w-1/3 cursor-pointer justify-center p-2 text-stone-600 transition hover:text-stone-950 dark:text-stone-300 dark:hover:text-stone-50"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
        title="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative z-10 flex w-1/3 cursor-pointer justify-center p-2 text-stone-600 transition hover:text-stone-950 dark:text-stone-300 dark:hover:text-stone-50"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
        title="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
