defmodule Streamix.TestSupport.SyncProviderWorkerIptvStub do
  @moduledoc false

  alias Streamix.Iptv

  def get_provider(id), do: Iptv.get_provider(id)
  def get_provider!(id), do: Iptv.get_provider!(id)
  def update_provider(provider, attrs), do: Iptv.update_provider(provider, attrs)
  def sync_provider(_provider, _opts), do: {:ok, %{live: 0, movies: 0, series: 0}}
end
