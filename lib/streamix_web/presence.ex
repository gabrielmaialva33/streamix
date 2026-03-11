defmodule StreamixWeb.Presence do
  use Phoenix.Presence,
    otp_app: :streamix,
    pubsub_server: Streamix.PubSub
end
