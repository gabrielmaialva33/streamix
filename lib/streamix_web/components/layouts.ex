defmodule StreamixWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality.
  """
  use StreamixWeb, :html

  import StreamixWeb.AppComponents

  embed_templates "layouts/*"
end
