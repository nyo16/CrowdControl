defmodule CrowdControl.RateLimit do
  @moduledoc """
  A typed view of Claude Code's `rate_limit_event`.

  Sessions broadcast the raw frame as `{:rate_limit, map}`, like every other
  message, and emit `[:crowd_control, :rate_limit]` telemetry with this struct
  under `:rate_limit`. Build one from a message with `from_event/1`:

      receive do
        {:crowd_control, _pid, {:rate_limit, _} = event} ->
          {:ok, %CrowdControl.RateLimit{status: :rejected, resets_at: at}} =
            CrowdControl.RateLimit.from_event(event)
      end

  ## Fields

    * `:status` - `:allowed`, `:allowed_warning`, `:rejected`, or `:unknown`
      for a status this version does not know
    * `:rate_limit_type` - the window that applies (`"five_hour"`,
      `"seven_day"`, ...), or `nil`
    * `:resets_at` - when that window resets, in Unix seconds, or `nil`
    * `:utilization` - how much of the window is used, `0.0..1.0`, or `nil`
    * `:unified_windows` - every window the CLI reported, keyed by name, each
      `%{"utilization" => _, "resetsAt" => _}` as sent; `%{}` when absent
    * `:raw` - the whole frame
  """

  @type status :: :allowed | :allowed_warning | :rejected | :unknown

  @type t :: %__MODULE__{
          status: status(),
          rate_limit_type: String.t() | nil,
          resets_at: integer() | nil,
          utilization: number() | nil,
          unified_windows: map(),
          raw: map()
        }

  defstruct [:status, :rate_limit_type, :resets_at, :utilization, :raw, unified_windows: %{}]

  @doc """
  Parse a `{:rate_limit, map}` message or its frame.

  Returns `:error` when the frame has no string `rate_limit_info.status`;
  `CrowdControl.Protocol` never tags such a frame `:rate_limit`.
  """
  @spec from_event({:rate_limit, map()} | map()) :: {:ok, t()} | :error
  def from_event({:rate_limit, frame}), do: from_event(frame)

  def from_event(%{"rate_limit_info" => %{"status" => status} = info} = frame)
      when is_binary(status) do
    {:ok,
     %__MODULE__{
       status: status(status),
       rate_limit_type: binary(info["rateLimitType"]),
       resets_at: if(is_integer(info["resetsAt"]), do: info["resetsAt"]),
       utilization: if(is_number(info["utilization"]), do: info["utilization"]),
       unified_windows: if(is_map(info["unifiedWindows"]), do: info["unifiedWindows"], else: %{}),
       raw: frame
     }}
  end

  def from_event(_other), do: :error

  defp status("allowed"), do: :allowed
  defp status("allowed_warning"), do: :allowed_warning
  defp status("rejected"), do: :rejected
  defp status(_other), do: :unknown

  defp binary(value) when is_binary(value), do: value
  defp binary(_value), do: nil
end
