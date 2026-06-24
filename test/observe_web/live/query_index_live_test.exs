defmodule ObserveWeb.QueryIndexLiveTest do
  use ObserveWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders first-class queries", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/queries")

    assert has_element?(view, "#query-index")
    assert has_element?(view, "#query-node-request_rate")
    assert has_element?(view, "#query-node-failed_checkouts")
  end

  test "collapses and expands query folders", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/queries")

    assert has_element?(view, "#query-node-failed_checkouts")

    view
    |> element("#query-folder-business button")
    |> render_click()

    refute has_element?(view, "#query-node-failed_checkouts")

    view
    |> element("#query-folder-business button")
    |> render_click()

    assert has_element?(view, "#query-node-failed_checkouts")
  end

  test "query rows navigate to query pages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/queries")

    assert {:error, {:live_redirect, %{to: "/queries/request_rate"}}} =
             view
             |> element("#query-node-request_rate")
             |> render_click()
  end
end
