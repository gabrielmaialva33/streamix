defmodule StreamixWeb.UrlValidator do
  @moduledoc """
  Compatibility wrapper for `Streamix.Security.UrlValidator`.
  """

  @spec validate_url(String.t()) :: :ok | {:error, :unsafe_url}
  defdelegate validate_url(url), to: Streamix.Security.UrlValidator
end
