defmodule StreamixWeb.Gindex.MoviesLive do
  @moduledoc """
  DEPRECATED: Redirects to /browse/movies?source=gindex

  This module is kept for backwards compatibility.
  The GIndex content is now accessible via the unified browse page.
  """
  use StreamixWeb, :live_view

  def mount(params, _session, socket) do
    # Redirect to unified browse page with gindex source
    search = params["search"]

    path =
      if search && search != "" do
        ~p"/browse/movies?source=gindex&search=#{search}"
      else
        ~p"/browse/movies?source=gindex"
      end

    {:ok, push_navigate(socket, to: path, replace: true)}
  end
end
