defmodule HiraethWeb.Admin.IngestionLive do
  use HiraethWeb, :live_view

  import HiraethWeb.Admin.IngestionRegistryComponents
  import HiraethWeb.Admin.IngestionShellComponents
  import HiraethWeb.Admin.IngestionTimelineComponents

  alias Hiraeth.Accounts
  alias HiraethWeb.Admin.IngestionRegistry

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin ingestion registry")
     |> assign(:catalog_count, nil)
     |> assign(:can_mutate?, Accounts.admin_role?(socket.assigns.current_admin_user))
     |> stream(:providers, [])
     |> stream(:runs, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_registry(socket, params)}
  end

  @impl true
  def handle_event("pause-provider", %{"provider-id" => provider_id}, socket) do
    update_provider_enabled(socket, provider_id, false, "paused")
  end

  def handle_event("resume-provider", %{"provider-id" => provider_id}, socket) do
    update_provider_enabled(socket, provider_id, true, "resumed")
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{admin: @current_admin_user}}
      catalog_count={@catalog_count}
    >
      <section id="admin-ingestion-shell" class="archive-wash space-y-8 pb-8">
        <.admin_header current_admin_user={@current_admin_user} />
        <.summary_cards
          provider_count={@provider_count}
          enabled_count={@enabled_count}
          run_count={@run_count}
          artifact_count={@artifact_count}
        />

        <div class="grid gap-6 xl:grid-cols-[minmax(22rem,0.9fr)_minmax(0,1.4fr)]">
          <.provider_registry providers={@streams.providers} selected_provider={@selected_provider} />

          <section id="admin-provider-detail-panel" class="space-y-6">
            <.provider_detail selected_provider={@selected_provider} can_mutate?={@can_mutate?} />
            <.artifact_detail_panel artifact={@selected_artifact} />
            <.phase_status_panel phase_statuses={@phase_statuses} />
            <.run_timeline
              runs={@streams.runs}
              events_by_run={@events_by_run}
              snapshots_by_run={@snapshots_by_run}
            />
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp update_provider_enabled(socket, _provider_id, _enabled?, _verb)
       when not socket.assigns.can_mutate? do
    {:noreply,
     put_flash(socket, :error, "Only owner or admin operators can pause or resume schedules.")}
  end

  defp update_provider_enabled(socket, provider_id, enabled?, verb) do
    case IngestionRegistry.update_provider_enabled(
           provider_id,
           enabled?,
           socket.assigns.current_admin_actor
         ) do
      {:ok, updated_provider} ->
        socket =
          socket
          |> put_flash(:info, "Provider schedule #{verb}.")
          |> load_registry(%{"id" => updated_provider.id})

        {:noreply, socket}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, "Provider source was not found.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Provider source was not found.")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Schedule change was denied.")}
    end
  end

  defp load_registry(socket, params) do
    state = IngestionRegistry.load(params)

    socket
    |> assign(:provider_count, state.provider_count)
    |> assign(:enabled_count, state.enabled_count)
    |> assign(:selected_provider, state.selected_provider)
    |> assign(:selected_artifact, state.selected_artifact)
    |> assign(:run_count, state.run_count)
    |> assign(:artifact_count, state.artifact_count)
    |> assign(:events_by_run, state.events_by_run)
    |> assign(:snapshots_by_run, state.snapshots_by_run)
    |> assign(:phase_statuses, state.phase_statuses)
    |> stream(:providers, state.providers, reset: true)
    |> stream(:runs, state.provider_runs, reset: true)
  end
end
