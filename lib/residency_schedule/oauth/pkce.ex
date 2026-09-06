defmodule ResidencySchedule.OAuth.PKCE do
  @moduledoc """
  Proof Key for Code Exchange (RFC 7636), `S256` method only, as required by
  OAuth 2.1.
  """

  @doc """
  Computes the `S256` challenge for a verifier.

      iex> ResidencySchedule.OAuth.PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  """
  def challenge(verifier) when is_binary(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  @doc """
  Returns true when the verifier matches the stored challenge under the given
  method. Only `"S256"` is supported; anything else fails.

      iex> ResidencySchedule.OAuth.PKCE.verify?(
      ...>   "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
      ...>   "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
      ...>   "S256"
      ...> )
      true

      iex> ResidencySchedule.OAuth.PKCE.verify?("wrong", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "S256")
      false
  """
  def verify?(verifier, challenge, "S256") when is_binary(verifier) and is_binary(challenge) do
    Plug.Crypto.secure_compare(challenge(verifier), challenge)
  end

  def verify?(_verifier, _challenge, _method), do: false
end
