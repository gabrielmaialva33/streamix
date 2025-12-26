defmodule StreamixWeb.PageController do
  use StreamixWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
