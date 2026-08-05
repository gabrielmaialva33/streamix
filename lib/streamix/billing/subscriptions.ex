defmodule Streamix.Billing.Subscriptions do
  @moduledoc """
  Subscription lifecycle operations.
  """

  import Ecto.Query, warn: false

  alias Streamix.Billing.{Plan, Subscription, UserProjection}
  alias Streamix.Repo

  def cancel_subscription_by_external_reference!(external_reference)
      when is_binary(external_reference) do
    case Repo.get_by(Subscription, external_reference: external_reference) do
      nil ->
        nil

      %Subscription{} = subscription ->
        cancel_subscription!(subscription)
    end
  end

  # Mid-cycle plan changes can shrink expires_at (downgrade with no
  # proration, or a Stripe webhook arriving out of order). The old code
  # silently overwrote the DB value, so a user could lose access early
  # without any signal. We log a warning so an oncall can correlate the
  # webhook with the user complaint instead of guessing.
  defp maybe_warn_on_expires_shrink(
         %Subscription{expires_at: %DateTime{} = old},
         %DateTime{} = new
       ) do
    if DateTime.compare(new, old) == :lt do
      require Logger

      Logger.warning(
        "[Billing] subscription #{inspect(old)} expires_at shrank to #{inspect(new)}; " <>
          "verify Stripe payload ordering / proration policy"
      )
    end

    :ok
  end

  defp maybe_warn_on_expires_shrink(_subscription, _new), do: :ok

  def sync_provider_subscription!(%{id: user_id} = user, %Plan{} = plan, attrs)
      when is_integer(user_id) and is_map(attrs) do
    Repo.transaction(fn ->
      now = DateTime.utc_now(:second)
      external_reference = Map.fetch!(attrs, :external_reference)
      status = Map.fetch!(attrs, :status)

      if status == "active" do
        cancel_other_active_subscriptions!(user_id, external_reference, now)
      end

      subscription_attrs = %{
        status: status,
        source: Map.fetch!(attrs, :provider),
        external_reference: external_reference,
        starts_at: Map.get(attrs, :starts_at, now),
        expires_at: Map.get(attrs, :expires_at),
        canceled_at: Map.get(attrs, :canceled_at)
      }

      case Repo.get_by(Subscription, external_reference: external_reference) do
        nil ->
          %Subscription{}
          |> Subscription.create_changeset(user, plan, subscription_attrs)
          |> Repo.insert!()

        %Subscription{} = subscription ->
          maybe_warn_on_expires_shrink(subscription, subscription_attrs.expires_at)

          subscription
          |> Subscription.create_changeset(user, plan, subscription_attrs)
          |> Repo.update!()
      end
    end)
    |> case do
      {:ok, subscription} -> subscription
      {:error, reason} -> raise inspect(reason)
    end
  end

  def start_trial_subscription(%{id: user_id} = user, %Plan{trial_days: trial_days} = plan)
      when is_integer(user_id) and is_integer(trial_days) and trial_days > 0 do
    external_reference = "trial:#{user_id}:#{plan.id}"

    case Repo.get_by(Subscription, external_reference: external_reference) do
      nil ->
        now = DateTime.utc_now(:second)

        {:ok,
         ensure_manual_subscription!(user, plan, %{
           status: "active",
           source: "trial",
           external_reference: external_reference,
           starts_at: now,
           expires_at: DateTime.add(now, trial_days, :day)
         })}

      %Subscription{} ->
        {:error, :trial_already_used}
    end
  end

  def start_trial_subscription(_user, _plan), do: {:error, :trial_not_available}

  def ensure_default_free_subscription(%{id: user_id} = user) when is_integer(user_id) do
    case Repo.get_by(Plan, slug: default_free_plan_slug(), active: true) do
      %Plan{} = plan ->
        ensure_default_free_subscription(user, plan)

      nil ->
        {:error, :default_free_plan_not_found}
    end
  end

  defp ensure_default_free_subscription(%{id: user_id} = user, %Plan{} = plan)
       when is_integer(user_id) do
    now = DateTime.utc_now(:second)
    external_reference = default_free_subscription_reference(user)

    attrs = %{
      status: "active",
      source: "trial",
      external_reference: external_reference,
      starts_at: now,
      expires_at: default_free_expires_at(now, plan)
    }

    case Repo.get_by(Subscription, external_reference: external_reference) do
      nil ->
        %Subscription{}
        |> Subscription.create_changeset(user, plan, attrs)
        |> Repo.insert()

      %Subscription{} = subscription ->
        {:ok, subscription}
    end
  end

  def ensure_manual_subscription!(%{id: user_id} = user, %Plan{} = plan, attrs)
      when is_integer(user_id) and is_map(attrs) do
    attrs = Map.merge(%{source: "manual", status: "active"}, attrs)

    external_reference =
      Map.get(attrs, :external_reference) || manual_subscription_reference(user, plan)

    attrs = Map.put(attrs, :external_reference, external_reference)

    case Repo.get_by(Subscription, external_reference: external_reference) do
      nil ->
        %Subscription{}
        |> Subscription.create_changeset(user, plan, attrs)
        |> Repo.insert!()

      %Subscription{} = subscription ->
        attrs = Map.put(attrs, :starts_at, subscription.starts_at)

        subscription
        |> Subscription.create_changeset(user, plan, attrs)
        |> Repo.update!()
    end
  end

  def create_manual_subscription(%{id: user_id} = user, %Plan{} = plan, attrs)
      when is_integer(user_id) and is_map(attrs) do
    %Subscription{}
    |> Subscription.create_changeset(user, plan, Map.merge(%{source: "manual"}, attrs))
    |> Repo.insert()
  end

  def cancel_subscription!(%Subscription{} = subscription) do
    subscription
    |> Ecto.Changeset.change(%{
      status: "canceled",
      canceled_at: DateTime.utc_now(:second)
    })
    |> Repo.update!()
  end

  def list_subscriptions(opts \\ []) do
    query = from(s in Subscription, preload: [:plan], order_by: [desc: s.inserted_at])

    query =
      case Keyword.get(opts, :user_id) do
        nil -> query
        user_id -> from(s in query, where: s.user_id == ^user_id)
      end

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(s in query, where: s.status == ^status)
      end

    query
    |> Repo.all()
    |> UserProjection.attach_emails()
  end

  def cancel_other_active_subscriptions!(user_id, external_reference, now) do
    from(s in Subscription,
      where: s.user_id == ^user_id and s.status == "active",
      where: s.external_reference != ^external_reference or is_nil(s.external_reference)
    )
    |> Repo.update_all(set: [status: "canceled", canceled_at: now, updated_at: now])
  end

  defp manual_subscription_reference(%{id: user_id}, %Plan{id: plan_id}) do
    "seed:manual:#{user_id}:#{plan_id}"
  end

  defp default_free_plan_slug, do: "free-trial"

  defp default_free_subscription_reference(%{id: user_id}) do
    "trial:signup:#{user_id}"
  end

  defp default_free_expires_at(now, %Plan{trial_days: trial_days})
       when is_integer(trial_days) and trial_days > 0 do
    DateTime.add(now, trial_days, :day)
  end

  defp default_free_expires_at(_now, _plan), do: nil
end
