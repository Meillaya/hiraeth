defmodule HiraethWeb.EditionLive.Components do
  use HiraethWeb, :html

  alias HiraethWeb.CatalogComponents

  def not_found(assigns) do
    ~H"""
    <div id="edition-detail-shell" class="archive-wash space-y-10 pb-12">
      <CatalogComponents.empty_state
        id="edition-not-found"
        title="No edition matches"
        message="No edition matches that slug. The archive did not fabricate a placeholder record."
        action_label="Back to browse"
        action_path="/browse"
      />
    </div>
    """
  end
end
