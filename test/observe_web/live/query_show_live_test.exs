defmodule ObserveWeb.QueryShowLiveTest do
  use ObserveWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders query detail and raw model", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/queries/queue_size")

    assert has_element?(view, "#query-show")
    assert has_element?(view, "#query-definition")
    assert has_element?(view, "#query-metadata")
    assert has_element?(view, "#query-raw-model")
    assert render(view) =~ "Queue size by deployment, priority, and state."
  end

  test "redirects unknown queries back to query index", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/queries"}}} = live(conn, ~p"/queries/missing-query")
  end
end
