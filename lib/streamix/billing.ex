defmodule Streamix.Billing do
  @moduledoc """
  Billing context for plans and subscriptions.
  """

  import Ecto.Query, warn: false

  alias Streamix.Accounts.User
  alias Streamix.Billing.Subscription
  alias Streamix.Repo

  def subscribed?(%User{id: user_id}) do
    now = DateTime.utc_now()

    from(s in Subscription,
      where: s.user_id == ^user_id and s.status == "active",
      where: is_nil(s.expires_at) or s.expires_at > ^now
    )
    |> Repo.exists?()
  end

  def subscribed?(_user), do: false

  def active_subscription_for_user(%User{id: user_id}) do
    now = DateTime.utc_now()

    from(s in Subscription,
      where: s.user_id == ^user_id and s.status == "active",
      where: is_nil(s.expires_at) or s.expires_at > ^now,
      preload: [:plan],
      order_by: [desc: s.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  def active_subscription_for_user(_user), do: nil
end
