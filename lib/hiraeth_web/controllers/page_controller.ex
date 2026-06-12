defmodule HiraethWeb.PageController do
  use HiraethWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
