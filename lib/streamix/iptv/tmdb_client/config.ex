defmodule Streamix.Iptv.TmdbClient.Config do
  @moduledoc false

  @type profile :: :default | :gindex

  @spec enabled?(profile()) :: boolean()
  def enabled?(profile \\ :default) do
    cfg = config(profile)
    cfg[:enabled] == true && is_binary(cfg[:api_token]) && cfg[:api_token] != ""
  end

  @spec profile_from(term()) :: profile()
  def profile_from(opts) when is_list(opts),
    do: opts |> Keyword.get(:profile) |> normalize_profile()

  def profile_from(%{} = opts), do: opts |> Map.get(:profile) |> normalize_profile()
  def profile_from(_), do: :default

  @spec config(profile()) :: keyword()
  def config(:default), do: Application.get_env(:streamix, :tmdb, [])

  def config(:gindex) do
    default = Application.get_env(:streamix, :tmdb, [])
    override = Application.get_env(:streamix, :tmdb_gindex, [])
    Keyword.merge(default, override)
  end

  def config(_unsupported_profile), do: config(:default)

  defp normalize_profile(:gindex), do: :gindex
  defp normalize_profile(_profile), do: :default
end
