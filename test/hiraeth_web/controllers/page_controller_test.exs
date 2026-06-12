defmodule HiraethWeb.PageControllerTest do
  use HiraethWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Hiraeth Editorial Archive"
  end
end
