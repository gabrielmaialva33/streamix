defmodule StreamixWeb.Helpers.ClientStorage do
  @moduledoc "Opaque account namespaces for browser storage; never an authorization credential."

  def scope(%{user: %{id: id}}) when is_integer(id) do
    :crypto.mac(
      :hmac,
      :sha256,
      StreamixWeb.Endpoint.config(:secret_key_base),
      "client-storage:#{id}"
    )
    |> Base.url_encode64(padding: false)
  end

  def scope(_scope), do: nil
end
