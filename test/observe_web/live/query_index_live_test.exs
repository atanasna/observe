defmodule ObserveWeb.QueryIndexLiveTest do
  use ObserveWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders first-class queries", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/queries")

    assert has_element?(view, "#query-index")
    assert has_element?(view, "#query-node-queue_size")
    assert has_element?(view, "#query-node-queue_jobs_et")
  end

  test "collapses and expands query folders", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/queries")

    assert has_element?(view, "#query-node-queue_size")

    view
    |> element("#query-folder-applications-queues button")
    |> render_click()

    refute has_element?(view, "#query-node-queue_size")

    view
    |> element("#query-folder-applications-queues button")
    |> render_click()

    assert has_element?(view, "#query-node-queue_size")
  end

  test "query rows navigate to query pages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/queries")

    assert {:error, {:live_redirect, %{to: "/queries/queue_size"}}} =
             view
             |> element("#query-node-queue_size")
             |> render_click()
  end
end
