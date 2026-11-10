defmodule StreamixWeb.Api.V1.FallbackController do
  @moduledoc "Translates explicit API failures into the stable v1 error envelope."

  use StreamixWeb, :controller

  alias StreamixWeb.Api.V1.Response

  def call(conn, {:error, :invalid_id, message}) do
    Response.error(conn, :bad_request, "invalid_id", message)
  end

  def call(conn, {:error, status, code, message}) do
    Response.error(conn, status, code, message)
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    Response.error(
      conn,
      :unprocessable_entity,
      "validation_failed",
      Response.changeset_message(changeset)
    )
  end
end
