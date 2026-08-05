defmodule Streamix.Billing.UserProjection do
  @moduledoc """
  Enriches billing records with account-owned display data.

  Billing persists only `user_id`; display projections come through the
  Accounts facade so Billing never imports the user schema.
  """

  alias Streamix.Accounts

  @spec attach_emails([struct()]) :: [struct()]
  def attach_emails(records) when is_list(records) do
    emails =
      records
      |> Enum.map(& &1.user_id)
      |> Accounts.user_email_map()

    Enum.map(records, fn record ->
      %{record | user_email: Map.get(emails, record.user_id)}
    end)
  end
end
