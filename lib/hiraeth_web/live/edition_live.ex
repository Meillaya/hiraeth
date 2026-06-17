defmodule HiraethWeb.EditionLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.EditionLive.Components
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Edition")}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    case PublicCatalog.book(slug) do
      %{slug: book_slug} ->
        {:noreply, push_navigate(socket, to: ~p"/books/#{book_slug}")}

      nil ->
        {:noreply, assign(socket, :edition, nil)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <Components.not_found />
    </Layouts.app>
    """
  end
end
