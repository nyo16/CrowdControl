defmodule CrowdControl.RateLimitTest do
  use ExUnit.Case, async: true

  alias CrowdControl.RateLimit

  # The 2.1.292 frame shape (research/wire-shapes.md §2).
  @frame %{
    "type" => "rate_limit_event",
    "session_id" => "s",
    "rate_limit_info" => %{
      "status" => "rejected",
      "rateLimitType" => "five_hour",
      "resetsAt" => 1_762_800_000,
      "utilization" => 1.0,
      "unifiedWindows" => %{"five_hour" => %{"utilization" => 1.0, "resetsAt" => 1_762_800_000}},
      "overageStatus" => "rejected"
    }
  }

  test "reads every field the CLI sends, keeping the frame" do
    assert {:ok,
            %RateLimit{
              status: :rejected,
              rate_limit_type: "five_hour",
              resets_at: 1_762_800_000,
              utilization: 1.0,
              unified_windows: %{"five_hour" => %{"resetsAt" => 1_762_800_000}},
              raw: @frame
            }} = RateLimit.from_event({:rate_limit, @frame})
  end

  test "maps each known status and anything else to :unknown, creating no atoms" do
    for {wire, status} <- [
          {"allowed", :allowed},
          {"allowed_warning", :allowed_warning},
          {"rejected", :rejected},
          {"throttled_by_a_future_cli", :unknown}
        ] do
      frame = %{"rate_limit_info" => %{"status" => wire}}
      assert {:ok, %RateLimit{status: ^status}} = RateLimit.from_event(frame)
    end
  end

  test "absent or mistyped optional fields are nil, windows default to %{}" do
    frame = %{
      "rate_limit_info" => %{
        "status" => "allowed",
        "rateLimitType" => 5,
        "resetsAt" => "soon",
        "utilization" => "high",
        "unifiedWindows" => []
      }
    }

    assert {:ok,
            %RateLimit{
              rate_limit_type: nil,
              resets_at: nil,
              utilization: nil,
              unified_windows: %{}
            }} =
             RateLimit.from_event(frame)
  end

  test "a frame without a string status is :error" do
    for frame <- [%{}, %{"rate_limit_info" => %{"status" => 1}}, %{"rate_limit_info" => "x"}, nil] do
      assert RateLimit.from_event(frame) == :error
    end
  end
end
