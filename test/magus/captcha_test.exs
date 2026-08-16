defmodule Magus.CaptchaTest do
  use ExUnit.Case, async: false

  import Mox

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:magus, :captcha)
    on_exit(fn -> Application.put_env(:magus, :captcha, original) end)
    :ok
  end

  defp enable! do
    Application.put_env(:magus, :captcha,
      impl: Magus.CaptchaImplMock,
      site_key: "sk",
      secret_key: "sec"
    )
  end

  test "disabled means :ok without calling the impl" do
    Application.put_env(:magus, :captcha, impl: Magus.CaptchaImplMock)
    assert :ok == Magus.Captcha.verify(%{}, nil)
  end

  test "missing token" do
    enable!()
    assert {:error, :missing_token} == Magus.Captcha.verify(%{}, {1, 2, 3, 4})
  end

  test "valid token" do
    enable!()

    expect(Magus.CaptchaImplMock, :verify, fn %{"cf-turnstile-response" => "tok"}, _ip ->
      {:ok, %{"success" => true}}
    end)

    assert :ok == Magus.Captcha.verify(%{"cf-turnstile-response" => "tok"}, {1, 2, 3, 4})
  end

  test "cloudflare rejection maps to invalid_token" do
    enable!()
    expect(Magus.CaptchaImplMock, :verify, fn _, _ -> {:error, %{"success" => false}} end)

    assert {:error, :invalid_token} ==
             Magus.Captcha.verify(%{"cf-turnstile-response" => "x"}, nil)
  end

  test "transport failure maps to verification_unavailable (fail closed)" do
    enable!()
    expect(Magus.CaptchaImplMock, :verify, fn _, _ -> {:error, :timeout} end)

    assert {:error, :verification_unavailable} ==
             Magus.Captcha.verify(%{"cf-turnstile-response" => "x"}, nil)
  end

  test "half-configuration raises at validate_config!" do
    Application.put_env(:magus, :captcha, site_key: "sk", secret_key: nil)
    assert_raise RuntimeError, ~r/half-configured/, &Magus.Captcha.validate_config!/0
  end

  test "empty-string keys count as unset: disabled, not half-configured" do
    Application.put_env(:magus, :captcha, site_key: "", secret_key: "")
    assert :ok == Magus.Captcha.validate_config!()
    refute Magus.Captcha.enabled?()
  end

  test "one empty key and one set key is half-configuration: validate_config! raises" do
    Application.put_env(:magus, :captcha, site_key: "", secret_key: "sec")
    assert_raise RuntimeError, ~r/half-configured/, &Magus.Captcha.validate_config!/0
  end

  test "an empty-string secret with a real site key does not enable captcha" do
    Application.put_env(:magus, :captcha,
      impl: Magus.CaptchaImplMock,
      site_key: "sk",
      secret_key: ""
    )

    refute Magus.Captcha.enabled?()
    # Disabled means verify/2 short-circuits to :ok without calling the impl,
    # even with an empty secret — never a silent Cloudflare test-key fallback.
    assert :ok == Magus.Captcha.verify(%{}, nil)
  end
end
