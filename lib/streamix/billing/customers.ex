defmodule Streamix.Billing.Customers do
  @moduledoc """
  Billing-provider customer records.
  """

  import Ecto.Query, warn: false

  alias Streamix.Accounts.User
  alias Streamix.Billing.BillingCustomer
  alias Streamix.Repo

  def get_billing_customer(%User{id: user_id}, provider) do
    Repo.get_by(BillingCustomer, user_id: user_id, provider: normalize_provider(provider))
  end

  def list_billing_customers(provider) do
    from(c in BillingCustomer,
      where: c.provider == ^normalize_provider(provider),
      preload: [:user],
      order_by: [asc: c.id]
    )
    |> Repo.all()
  end

  def upsert_billing_customer!(%User{} = user, provider, external_id, metadata \\ %{})
      when is_binary(external_id) and external_id != "" do
    attrs = %{
      user_id: user.id,
      provider: normalize_provider(provider),
      external_id: external_id,
      metadata: metadata || %{}
    }

    case Repo.get_by(BillingCustomer, user_id: user.id, provider: attrs.provider) do
      nil ->
        %BillingCustomer{}
        |> BillingCustomer.changeset(attrs)
        |> Repo.insert!()

      %BillingCustomer{} = customer ->
        customer
        |> BillingCustomer.changeset(attrs)
        |> Repo.update!()
    end
  end

  defp normalize_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp normalize_provider(provider) when is_binary(provider), do: provider
end
