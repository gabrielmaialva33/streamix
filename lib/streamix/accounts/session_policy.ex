defmodule Streamix.Accounts.SessionPolicy do
  @moduledoc """
  Central lifetime policy for browser and API authentication sessions.

  Keeping the database token validity and persistent browser cookie in one
  place prevents a valid cookie from outliving the token it carries.
  """

  @validity_in_days 60
  @seconds_per_day 24 * 60 * 60

  @spec validity_in_days() :: pos_integer()
  def validity_in_days, do: @validity_in_days

  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds, do: @validity_in_days * @seconds_per_day
end
