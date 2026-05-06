defmodule Streamix.Iptv.TmdbClient.Config do
  @moduledoc false

  def enabled?(profile \\ :default) do
    cfg = config(profile)
    cfg[:enabled] == true && is_binary(cfg[:api_token]) && cfg[:api_token] != ""
  end

  def profile_from(opts) when is_list(opts), do: Keyword.get(opts, :profile, :default)
  def profile_from(%{} = opts), do: Map.get(opts, :profile, :default)
  def profile_from(_), do: :default

  def config(:default), do: Application.get_env(:streamix, :tmdb, [])

  def config(profile) when is_atom(profile) do
    default = Application.get_env(:streamix, :tmdb, [])
    override = Application.get_env(:streamix, :"tmdb_#{profile}", [])
    Keyword.merge(default, override)
  end
end
