defmodule Azimutt.Accounts do
  @moduledoc "The Accounts context."
  import Ecto.Query, warn: false
  alias Azimutt.Repo
  alias Azimutt.Accounts.{User, UserNotifier, UserToken}
  alias Azimutt.Organizations
  alias Azimutt.Organizations.OrganizationMember
  alias Azimutt.Utils.Crypto
  alias Azimutt.Utils.Result

  ## Database getters

  def get_user(id) when is_binary(id) do
    Repo.get(User, id)
    |> Repo.preload([:organizations])
    |> Result.from_nillable()
  end

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
    |> Repo.preload([:organizations])
    |> Result.from_nillable()
  end

  def get_user_by_email_and_password(email, password) when is_binary(email) and is_binary(password) do
    get_user_by_email(email)
    |> Result.filter(fn user -> User.valid_password?(user, password) end, :not_found)
  end

  ## User registration

  def change_user_registration(attrs, %User{} = user, now) do
    User.password_creation_changeset(user, attrs, now, hash_password: false)
  end

  def register_password_user(attrs, now) do
    register_user(%User{} |> User.password_creation_changeset(attrs, now))
  end

  def register_github_user(attrs, now) do
    register_user(%User{} |> User.github_creation_changeset(attrs, now))
  end

  def register_heroku_user(email, now) do
    attrs = %{
      name: email |> String.split("@") |> hd(),
      email: email,
      avatar: "https://www.gravatar.com/avatar/#{Crypto.md5(email)}?s=150&d=robohash",
      provider: "heroku"
    }

    register_user(%User{} |> User.heroku_creation_changeset(attrs, now))
  end

  defp register_user(changeset) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, changeset)
    |> Ecto.Multi.run(:organization, fn _repo, %{user: user} -> Organizations.create_personal_organization(user) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} ->
        if Azimutt.config(:global_organization) do
          OrganizationMember.new_member_changeset(Azimutt.config(:global_organization), user) |> Repo.insert()
        end

        {:ok, user}

      {:error, :user, changeset, _} ->
        {:error, changeset}
    end
  end

  ## Settings

  def change_user_email(user, attrs \\ %{}) do
    User.email_changeset(user, attrs)
  end

  # FIXME : Dois être complètement changé
  def change_user_profil(user, attrs, now) do
    User.github_creation_changeset(user, attrs, now)
  end

  def update_user_profil(%User{} = user, attrs, now) do
    user
    |> change_user_profil(attrs, now)
    |> Repo.update()
  end

  def apply_user_email(user, password, attrs) do
    user
    |> User.email_changeset(attrs)
    |> User.validate_current_password(password)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  The confirmed_at date is also updated to the current time.
  """
  def update_user_email(user, token, now) do
    context = "change:#{user.email}"

    with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
         %UserToken{sent_to: email} <- Repo.one(query),
         {:ok, _} <- Repo.transaction(user_email_multi(user, email, context, now)) do
      :ok
    else
      _ -> :error
    end
  end

  defp user_email_multi(user, email, context, now) do
    changeset =
      user
      |> User.email_changeset(%{email: email})
      |> User.confirm_changeset(now)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, [context]))
  end

  def deliver_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  def change_user_password(user, attrs \\ %{}) do
    User.password_changeset(user, attrs, hash_password: false)
  end

  def update_user_password(user, password, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(password)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  ## Session

  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  def delete_session_token(token) do
    Repo.delete_all(UserToken.token_and_context_query(token, "session"))
    :ok
  end

  ## Confirmation

  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  def confirm_user(token, now) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(confirm_user_multi(user, now)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp confirm_user_multi(user, now) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user, now))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["confirm"]))
  end

  ## Reset password

  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    UserNotifier.deliver_reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  def reset_user_password(user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.password_changeset(user, attrs))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  def get_user_organizations(%User{} = user) do
    if Azimutt.config(:global_organization) && Azimutt.config(:global_organization_alone) do
      user.organizations |> Enum.filter(fn orga -> orga.id == Azimutt.config(:global_organization) end)
    else
      user.organizations
    end
  end

  def get_user_default_organization(%User{} = user) do
    if Azimutt.config(:global_organization) do
      user.organizations
      |> Enum.filter(fn orga -> orga.id == Azimutt.config(:global_organization) end)
      |> List.first() || get_user_personal_organization(user)
    else
      get_user_personal_organization(user)
    end
  end

  def get_user_personal_organization(%User{} = user) do
    user.organizations
    |> Enum.filter(fn orga -> orga.is_personal == true end)
    |> List.first() || user.organizations |> List.first()
  end
end
