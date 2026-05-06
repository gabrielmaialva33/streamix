defmodule Streamix.Iptv.Sync.Series do
  @moduledoc """
  Public facade for series, season, and episode synchronization.
  """

  alias Streamix.Iptv.Sync.Series.{Details, Upsert}

  defdelegate sync_series(provider), to: Upsert
  defdelegate sync_all_series_details(provider), to: Details
  defdelegate sync_series_details(series), to: Details
end
