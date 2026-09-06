defmodule ResidencySchedule.OAuth.Secret do
  @moduledoc """
  Generates opaque, URL-safe secrets (codes, tokens, client ids) and hashes
  them for storage. Secrets are never stored in plaintext.
  """

  @doc """
  Generates a random URL-safe secret of the given byte length (default 32).

      iex> secret = ResidencySchedule.OAuth.Secret.generate()
      iex> String.length(secret)
      43

      iex> ResidencySchedule.OAuth.Secret.generate(16) |> String.length()
      22
  """
  def generate(bytes \\ 32) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Returns the hex-encoded SHA-256 digest of a secret, for storage and lookup.

      iex> ResidencySchedule.OAuth.Secret.hash("abc")
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  """
  def hash(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  @doc """
  Constant-time comparison of a plaintext secret against a stored hash.

      iex> hash = ResidencySchedule.OAuth.Secret.hash("abc")
      iex> ResidencySchedule.OAuth.Secret.matches?("abc", hash)
      true

      iex> hash = ResidencySchedule.OAuth.Secret.hash("abc")
      iex> ResidencySchedule.OAuth.Secret.matches?("abd", hash)
      false
  """
  def matches?(secret, stored_hash) when is_binary(secret) and is_binary(stored_hash) do
    Plug.Crypto.secure_compare(hash(secret), stored_hash)
  end

  def matches?(_secret, _stored_hash), do: false
end
