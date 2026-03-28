defmodule StreamixWeb.Presence do
  @moduledoc """
  Presence tracker for LiveView and PubSub presence metadata.
  """

  use Phoenix.Presence,
    otp_app: :streamix,
    pubsub_server: Streamix.PubSub
end
