defmodule Streamix.TestSupport.SyncProviderWorkerIptvStub do
  @moduledoc false

  def get_provider(id), do: Streamix.Providers.get_provider(id)
  def get_provider!(id), do: Streamix.Providers.get_provider!(id)
  def update_provider(provider, attrs), do: Streamix.Providers.update_provider(provider, attrs)
  def sync_provider(_provider, _opts), do: {:ok, %{live: 0, movies: 0, series: 0}}
end

defmodule Streamix.TestSupport.FailingSyncProviderWorkerIptvStub do
  @moduledoc false

  def get_provider(id), do: Streamix.Providers.get_provider(id)
  def get_provider!(id), do: Streamix.Providers.get_provider!(id)
  def update_provider(provider, attrs), do: Streamix.Providers.update_provider(provider, attrs)
  def sync_provider(_provider, _opts), do: {:error, :forced_failure}
end
