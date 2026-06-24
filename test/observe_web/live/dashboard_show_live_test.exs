defmodule ObserveWeb.DashboardShowLiveTest do
  use ObserveWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders global time and refresh controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards/laravel")

    refute has_element?(view, "#dashboard-time-range")
    assert has_element?(view, "#dashboard-start-time")
    assert has_element?(view, "#dashboard-end-time")
    assert has_element?(view, "#dashboard-refresh-interval")
  end

  test "renders prometheus datasource variable selector", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards/laravel")

    assert has_element?(view, "#variables_source")
    assert render(view) =~ "eu-ds"
    assert render(view) =~ "us-ds"
  end

  test "renders dashboard while datasets are pulled in the background", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards/laravel")

    assert has_element?(view, "#refresh-dashboard")
    assert has_element?(view, "#panel-grid")
  end
end
