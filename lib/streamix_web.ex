defmodule StreamixWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use StreamixWeb, :controller
      use StreamixWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  # `sw.js` deliberately omitted — served dynamically by
  # `StreamixWeb.ServiceWorkerController` so each release ships a
  # fresh `CACHE_VERSION`. Static plug would otherwise hand back the
  # byte-identical file on every deploy, the browser would skip the
  # SW update step, and the old cache would stay pinned forever.
  # `manifest.json` is also omitted: like the service worker, it must be
  # revalidated on every launch so install metadata cannot stay pinned for
  # a year by Plug.Static's immutable production cache.
  def static_paths,
    do: ~w(assets fonts images favicon.ico robots.txt avplayer vendor offline.html)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: StreamixWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: StreamixWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import StreamixWeb.CoreComponents
      # Application-specific components. Import the defining modules directly
      # so Phoenix retains each component's attr/slot contract at call sites.
      import StreamixWeb.App.Feedback
      import StreamixWeb.App.Filters
      import StreamixWeb.App.Media
      import StreamixWeb.App.Navigation
      import StreamixWeb.App.Premium
      # Content components (movies, series, navigation, carousels)
      import StreamixWeb.Content.CardComponents
      import StreamixWeb.Content.CarouselComponents
      import StreamixWeb.Content.DetailComponents
      import StreamixWeb.Content.NavigationComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias StreamixWeb.Helpers.ImageProxy
      alias StreamixWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: StreamixWeb.Endpoint,
        router: StreamixWeb.Router,
        statics: StreamixWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
