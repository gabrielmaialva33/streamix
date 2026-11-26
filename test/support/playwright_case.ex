defmodule StreamixWeb.PlaywrightCase do
  @moduledoc """
  Case template for browser tests: a Fluffy Playwright session as `conn`, in
  the test's SQL sandbox.
  """

  use ExUnit.CaseTemplate
  use Playwright.Test

  using opts do
    quote do
      use Playwright.Test, unquote(opts)
      import Fluffy.PhoenixTest
      import StreamixWeb.PlaywrightCase, only: [log_in: 2]
    end
  end

  setup tags do
    Streamix.DataCase.setup_sandbox(tags)
    %{conn: Fluffy.PhoenixTest.start_session(:playwright)}
  end

  @doc """
  Logs `user` in without the login form: one request through the endpoint
  signs the session `ConnCase.log_in_user/2` builds, and the browser gets the
  cookie it writes. Add it before `visit/2`.
  """
  def log_in(session, user) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> StreamixWeb.ConnCase.log_in_user(user)
      |> Phoenix.ConnTest.dispatch(StreamixWeb.Endpoint, :get, "/browse/movies")

    cookies =
      for {name, %{value: value}} <- conn.resp_cookies,
          do: %{name: name, value: value, url: Fluffy.base_url(session)}

    Fluffy.add_cookies(session, cookies)
  end
end
