defmodule ObserveWeb.DashboardIndexLiveTest do
  use ObserveWeb.ConnCase

  import Phoenix.LiveViewTest

  test "collapses and expands dashboard folders", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards")

    assert has_element?(view, "#dashboard-node-laravel")

    view
    |> element("#dashboard-folder-Apps button")
    |> render_click()

    refute has_element?(view, "#dashboard-node-laravel")

    view
    |> element("#dashboard-folder-Apps button")
    |> render_click()

    assert has_element?(view, "#dashboard-node-laravel")
  end

  test "dashboard leaf rows navigate to dashboard pages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards")

    assert {:error, {:live_redirect, %{to: "/dashboards/laravel"}}} =
             view
             |> element("#dashboard-node-laravel")
             |> render_click()
  end
end
