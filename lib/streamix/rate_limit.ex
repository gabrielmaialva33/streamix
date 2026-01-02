defmodule Streamix.RateLimit do
  @moduledoc """
  Rate limiter module using Hammer 7.x.

  This module must be started in the application supervision tree.
  """

  use Hammer, backend: :ets
end
