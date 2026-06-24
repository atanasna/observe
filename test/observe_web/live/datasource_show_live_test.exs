defmodule ObserveWeb.DatasourceShowLiveTest do
  use ObserveWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders datasource configuration", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/datasources/eu-charge")

    assert html =~ "eu-charge"
    assert html =~ "prometheus"
    assert html =~ "https://prometheus.eu.infra.charge.ampeco.tech"
    assert html =~ "real"
  end
end
