defmodule Streamix.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Streamix.Accounts.{IpTracker, Role, Scope, SessionPolicy, User, UserNotifier, UserToken}
  alias Streamix.Billing
  alias Streamix.Repo

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    case Repo.get_by(User, email: email) do
      nil -> nil
      user -> Repo.preload(user, :role)
    end
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id) |> Repo.preload(:role)

  @doc """
  Gets a single user or returns `nil`.
  """
  def get_user(id, opts \\ []) do
    case Repo.get(User, id) do
      nil -> nil
      %User{} = user -> maybe_preload_user_role(user, opts)
    end
  end

  @doc """
  Ensures a user has its role association loaded.
  """
  def preload_role(%User{} = user, opts \\ []) do
    Repo.preload(user, :role, opts)
  end

  defp maybe_preload_user_role(%User{} = user, opts) do
    if Keyword.get(opts, :preload_role, false), do: preload_role(user), else: user
  end

  ## User registration

  @doc """
  Builds a registration changeset without exposing the user schema to web callers.
  """
  def new_user_registration(attrs \\ %{}, opts \\ []) do
    User.registration_changeset(%User{}, attrs, opts)
  end

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers a user with email and password.

  ## Examples

      iex> register_user_with_password(%{email: "test@example.com", password: "secret123456"})
      {:ok, %User{}}

      iex> register_user_with_password(%{email: "bad"})
      {:error, %Ecto.Changeset{}}

  """
  def register_user_with_password(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> ensure_default_role()
    |> Repo.insert()
    |> maybe_attach_default_free_subscription()
  end

  defp maybe_attach_default_free_subscription({:ok, %User{} = user}) do
    case Billing.ensure_default_free_subscription(user) do
      {:ok, _subscription} -> {:ok, user}
      {:error, :default_free_plan_not_found} -> {:ok, user}
      {:error, _changeset_or_reason} -> {:ok, user}
    end
  end

  defp maybe_attach_default_free_subscription(result), do: result

  defp ensure_default_role(changeset) do
    if Ecto.Changeset.get_field(changeset, :role_id) do
      changeset
    else
      Ecto.Changeset.put_change(changeset, :role_id, customer_role_id())
    end
  end

  @doc """
  Finds or creates a user and guarantees the admin role.
  """
  def ensure_admin_user!(email, password) when is_binary(email) and is_binary(password) do
    user =
      case get_user_by_email(email) do
        nil ->
          {:ok, user} = register_user_with_password(%{email: email, password: password})
          user

        %User{} = user ->
          user
      end

    if admin?(user) do
      user
    else
      {:ok, admin_user} = make_admin_user(user)
      admin_user
    end
  end

  def make_admin_user(%User{} = user) do
    user
    |> User.role_changeset(admin_role_id())
    |> Repo.update()
  end

  def admin?(%User{role_id: role_id}), do: role_id == admin_role_id()
  def admin?(_user), do: false

  @doc """
  Returns the role name for a user. Preloads the role if needed.
  """
  def role_name(%User{role: %Role{name: name}}), do: name

  def role_name(%User{} = user) do
    user = Repo.preload(user, :role)
    user.role.name
  end

  @doc """
  Returns the cached admin role id.
  """
  def admin_role_id do
    case Repo.get_by(Role, name: "admin") do
      %Role{id: id} -> id
      nil -> raise "Admin role not found in database"
    end
  end

  @doc """
  Returns the cached customer role id.
  """
  def customer_role_id do
    case Repo.get_by(Role, name: "customer") do
      %Role{id: id} -> id
      nil -> raise "Customer role not found in database"
    end
  end

  @doc """
  Gets a role by name.
  """
  def get_role_by_name!(name) when is_binary(name) do
    Repo.get_by!(Role, name: name)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user registration changes.

  ## Examples

      iex> change_user_registration(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(user, attrs, opts)
  end

  @doc """
  Builds the authenticated request scope for a user.
  """
  defdelegate scope_for_user(user), to: Scope, as: :for_user

  @doc """
  Extracts the session metadata persisted with an authenticated request.
  """
  defdelegate request_info(conn), to: IpTracker, as: :get_request_info

  @doc """
  Records an access event without blocking the request.
  """
  defdelegate log_access_async(conn, user_id), to: IpTracker

  @doc """
  Returns the normalized client IP used by request rate limiting.
  """
  defdelegate client_ip(conn), to: IpTracker, as: :get_client_ip

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Streamix.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Streamix.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing user settings.

  ## Examples

      iex> change_user_settings(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_settings(user, attrs \\ %{}) do
    User.settings_changeset(user, attrs)
  end

  @doc """
  Updates user settings (like show_adult_content).

  ## Examples

      iex> update_user_settings(user, %{show_adult_content: true})
      {:ok, %User{}}

  """
  def update_user_settings(user, attrs) do
    user
    |> User.settings_changeset(attrs)
    |> Repo.update()
    |> invalidate_user_cache()
  end

  ## Admin functions

  @doc """
  Lists users with optional search and pagination.

  ## Options

    * `:search` - Filters users by email (ilike).
    * `:page` - Page number (default 1).
    * `:per_page` - Results per page (default 20).
  """
  def list_users(opts \\ []) do
    search = Keyword.get(opts, :search)
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    User
    |> users_query()
    |> filter_users_by_email(search)
    |> paginate_users(page, per_page)
    |> Repo.all()
  end

  defp users_query(queryable) do
    from(user in queryable,
      as: :user,
      order_by: [desc: user.inserted_at],
      preload: [:role]
    )
  end

  defp filter_users_by_email(query, nil), do: query
  defp filter_users_by_email(query, ""), do: query

  defp filter_users_by_email(query, search) when is_binary(search) do
    term = "%#{search}%"
    from([user: user] in query, where: ilike(user.email, ^term))
  end

  defp paginate_users(query, page, per_page) do
    offset = (page - 1) * per_page
    from(query, limit: ^per_page, offset: ^offset)
  end

  @doc """
  Returns the total number of users.
  """
  def count_users do
    Repo.aggregate(User, :count)
  end

  @doc """
  Updates the role of a user. Accepts a role name (string) or role_id (integer).
  """
  def update_user_role(%User{} = user, role_name) when is_binary(role_name) do
    role = get_role_by_name!(role_name)
    update_user_role(user, role.id)
  end

  def update_user_role(%User{} = user, role_id) when is_integer(role_id) do
    user
    |> User.role_changeset(role_id)
    |> Repo.update()
  end

  @doc """
  Updates user settings from admin panel (e.g. show_adult_content).
  """
  def update_user_settings_admin(%User{} = user, attrs) do
    user
    |> User.settings_changeset(attrs)
    |> Repo.update()
    |> invalidate_user_cache()
  end

  defp invalidate_user_cache({:ok, %User{id: user_id}} = result) do
    Streamix.Cache.invalidate_user(user_id)
    result
  end

  defp invalidate_user_cache(result), do: result

  ## Session

  @doc """
  Returns how long a persistent authentication session remains valid.
  """
  defdelegate session_max_age_seconds(), to: SessionPolicy, as: :max_age_seconds

  @doc """
  Generates a session token.
  Optionally accepts ip_info map with :ip_address, :user_agent, :country, :city
  """
  def generate_user_session_token(user, ip_info \\ %{}) do
    {token, user_token} = UserToken.build_session_token(user, ip_info)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    case Repo.one(query) do
      {user, inserted_at} -> {Repo.preload(user, :role), inserted_at}
      nil -> nil
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
