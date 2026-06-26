defmodule Magus.Usage.PolicyErrorMessageTest do
  use ExUnit.Case, async: true

  alias Magus.Usage.PolicyError
  alias Magus.Usage.PolicyErrorMessage

  describe "message/1" do
    test "formats spend_cap with CHF amounts and the spend-cap copy" do
      msg =
        PolicyErrorMessage.message(%PolicyError{
          limit_type: :spend_cap,
          current: 2000,
          limit: 2000
        })

      assert msg =~ "monthly spend cap"
      assert msg =~ "CHF 20.00/CHF 20.00"
      assert msg =~ "Raise your cap (or turn it off) in Settings to keep going."
    end

    test "formats trial_cap with CHF amounts and the trial copy" do
      msg =
        PolicyErrorMessage.message(%PolicyError{
          limit_type: :trial_cap,
          current: 100,
          limit: 500
        })

      assert msg =~ "free trial allowance"
      assert msg =~ "CHF 1.00/CHF 5.00"
      assert msg =~ "Subscribe to Pay-as-you-go in Settings to keep going."
    end

    test "formats payment_required with the update-payment CTA" do
      msg = PolicyErrorMessage.message(%PolicyError{limit_type: :payment_required})

      assert msg ==
               "Your last payment failed. Update your payment method to keep using pay-as-you-go."
    end

    test "formats mode_disabled" do
      msg = PolicyErrorMessage.message(%PolicyError{limit_type: :mode_disabled})

      assert msg == "This feature is not available on your current plan. Upgrade to access it."
    end

    test "formats storage_bytes with byte amounts" do
      msg =
        PolicyErrorMessage.message(%PolicyError{
          limit_type: :storage_bytes,
          current: 1_073_741_824,
          limit: 1_073_741_824
        })

      assert msg ==
               "Storage limit reached (1.0 GB/1.0 GB). Upgrade for more storage."
    end

    test "formats storage_overage" do
      msg = PolicyErrorMessage.message(%PolicyError{limit_type: :storage_overage})

      assert msg ==
               "You're over your storage limit. Please delete files or upgrade to upload new files."
    end

    test "formats max_upload_bytes with byte amount" do
      msg =
        PolicyErrorMessage.message(%PolicyError{
          limit_type: :max_upload_bytes,
          limit: 10_485_760
        })

      assert msg == "File too large. Maximum upload size is 10.0 MB."
    end

    test "formats workspace_model_restricted" do
      msg = PolicyErrorMessage.message(%PolicyError{limit_type: :workspace_model_restricted})

      assert msg ==
               "This model is not allowed in the current workspace. Choose an allowed model or switch to a personal conversation."
    end

    test "spend_cap with nil amounts renders CHF 0.00" do
      msg = PolicyErrorMessage.message(%PolicyError{limit_type: :spend_cap})

      assert msg =~ "CHF 0.00/CHF 0.00"
    end
  end

  describe "format_bytes (via storage messages) is byte-identical to the former web formatter" do
    # Each tuple is {byte_count, expected_rendered_substring}. These assert the
    # locally reimplemented format_bytes/1 produces the exact same output as the
    # deleted MagusWeb.Formatters.format_bytes/1.
    @byte_cases [
      {0, "0 B"},
      {512, "512 B"},
      {1024, "1.0 KB"},
      {1536, "1.5 KB"},
      {1_048_576, "1.0 MB"},
      {10_485_760, "10.0 MB"},
      {1_073_741_824, "1.0 GB"},
      {1_610_612_736, "1.5 GB"}
    ]

    for {bytes, expected} <- @byte_cases do
      test "renders #{bytes} bytes as #{expected}" do
        msg =
          PolicyErrorMessage.message(%PolicyError{
            limit_type: :max_upload_bytes,
            limit: unquote(bytes)
          })

        assert msg == "File too large. Maximum upload size is #{unquote(expected)}."
      end
    end
  end
end
