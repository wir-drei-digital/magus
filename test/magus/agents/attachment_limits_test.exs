defmodule Magus.Agents.AttachmentLimitsTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.AttachmentLimits

  test "exposes the configured caps" do
    assert AttachmentLimits.max_attachments_per_agent() == 20
    assert AttachmentLimits.max_always_include_tokens() == 30_000
    assert AttachmentLimits.always_include_warning_threshold() == 20_000
    assert AttachmentLimits.max_total_size_bytes() == 100 * 1024 * 1024
  end

  describe "exceeds_*" do
    test "exceeds_attachment_count?/1" do
      refute AttachmentLimits.exceeds_attachment_count?(20)
      assert AttachmentLimits.exceeds_attachment_count?(21)
    end

    test "exceeds_always_include_tokens?/1" do
      refute AttachmentLimits.exceeds_always_include_tokens?(30_000)
      assert AttachmentLimits.exceeds_always_include_tokens?(30_001)
    end

    test "exceeds_total_size?/1" do
      refute AttachmentLimits.exceeds_total_size?(100 * 1024 * 1024)
      assert AttachmentLimits.exceeds_total_size?(100 * 1024 * 1024 + 1)
    end
  end
end
