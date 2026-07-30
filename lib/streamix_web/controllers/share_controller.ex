defmodule StreamixWeb.ShareController do
  @moduledoc """
  Web Share Target endpoint (`share_target` in `priv/manifest.json`).

  When the installed PWA is picked in the OS share sheet, the browser
  opens `/share?title=...&text=...&url=...`. We land the user on search
  with the most useful shared term prefilled.
  """
  use StreamixWeb, :controller

  def index(conn, params) do
    query =
      ["title", "text", "url"]
      |> Enum.map(&params[&1])
      |> Enum.find("", &(is_binary(&1) and String.trim(&1) != ""))
      |> String.trim()

    if query == "" do
      redirect(conn, to: ~p"/search")
    else
      redirect(conn, to: ~p"/search?q=#{query}")
    end
  end
end
