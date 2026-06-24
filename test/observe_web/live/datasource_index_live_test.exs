defmodule ObserveWeb.DatasourceIndexLiveTest do
  use ObserveWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders datasource inventory grouped by folder", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/datasources")

    assert html =~ "Datasources"
    assert html =~ "Provisioning Tree"
    assert html =~ "real"
    assert html =~ "eu-charge"
  end

  test "collapses and expands datasource folders", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/datasources")

    assert has_element?(view, "#datasource-node-eu-charge")

    view
    |> element("#datasource-folder-real button")
    |> render_click()

    refute has_element?(view, "#datasource-node-eu-charge")

    view
    |> element("#datasource-folder-real button")
    |> render_click()

    assert has_element?(view, "#datasource-node-eu-charge")
  end

  test "datasource leaf rows navigate to datasource detail pages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/datasources")

    assert {:error, {:live_redirect, %{to: "/datasources/eu-charge"}}} =
             view
             |> element("#datasource-node-eu-charge")
             |> render_click()
  end
end
