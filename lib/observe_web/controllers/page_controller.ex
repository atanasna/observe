defmodule ObserveWeb.PageController do
  use ObserveWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
