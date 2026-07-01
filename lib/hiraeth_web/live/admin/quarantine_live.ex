defmodule HiraethWeb.Admin.QuarantineLive do
  use HiraethWeb, :live_view

  import HiraethWeb.Admin.IngestionShellComponents
  import HiraethWeb.Admin.QuarantineComponents

  alias Hiraeth.Accounts
  alias HiraethWeb.Admin.QuarantineControl

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin ingestion quarantine")
     |> assign(:catalog_count, nil)
     |> assign(:can_mutate?, Accounts.admin_role?(socket.assigns.current_admin_user))
     |> assign(
       :review_form,
       to_form(%{"reason" => "", "approve_destructive" => "false"}, as: :review)
     )
     |> stream(:runs, [])
     |> stream(:candidates, [])}
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, load_quarantine(socket, params)}

  @impl true
  def handle_event("review-candidate", params, socket) do
    candidate_id = params["candidate-id"]
    action = params["review_action"] || params["action"]
    review = params["review"] || %{}

    case QuarantineControl.review_candidate(
           candidate_id,
           action,
           review,
           socket.assigns.current_admin_actor
         ) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Candidate #{action} recorded.")
         |> load_quarantine(%{"candidate_id" => updated.id})}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("retry-run", %{"run-id" => run_id}, socket) do
    run_control(socket, run_id, &QuarantineControl.retry_run/2, "Retry job enqueued.")
  end

  def handle_event("replay-run", %{"run-id" => run_id}, socket) do
    run_control(socket, run_id, &QuarantineControl.replay_run/2, "Replay job enqueued.")
  end

  def handle_event("cancel-run", %{"run-id" => run_id}, socket) do
    run_control(socket, run_id, &QuarantineControl.cancel_run/2, "Run cancelled.")
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
      <section id="admin-quarantine-shell" class="archive-wash space-y-8 pb-8">
        <.admin_header
          current_admin_user={@current_admin_user}
          title="Quarantine and replay controls"
          deck="Review candidate diffs, record operator decisions, replay retained snapshots, and export audit artifacts."
        />
        <.quarantine_summary counts={@counts} />

        <div class="grid gap-6 xl:grid-cols-[minmax(20rem,0.85fr)_minmax(0,1.5fr)]">
          <.run_control_panel
            runs={@streams.runs}
            selected_run={@selected_run}
            can_mutate?={@can_mutate?}
          />
          <.candidate_review_panel
            candidates={@streams.candidates}
            selected_candidate={@selected_candidate}
            review_form={@review_form}
            can_mutate?={@can_mutate?}
          />
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp run_control(socket, run_id, fun, success) do
    case fun.(run_id, socket.assigns.current_admin_actor) do
      {:ok, _result} ->
        {:noreply, socket |> put_flash(:info, success) |> load_quarantine(%{"run_id" => run_id})}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp load_quarantine(socket, params) do
    state = QuarantineControl.load(params)

    socket
    |> assign(:selected_run, state.selected_run)
    |> assign(:selected_candidate, state.selected_candidate)
    |> assign(:counts, state.counts)
    |> stream(:runs, state.runs, reset: true)
    |> stream(:candidates, state.candidates, reset: true)
  end
end
