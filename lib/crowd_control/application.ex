defmodule CrowdControl.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    max_sessions = fetch_max_sessions!()

    children = [
      {DynamicSupervisor,
       name: CrowdControl.SessionSupervisor, strategy: :one_for_one, max_children: max_sessions}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CrowdControl.Supervisor)
  end

  defp fetch_max_sessions! do
    case Application.get_env(:crowd_control, :max_sessions, 50) do
      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise ArgumentError,
              "config :crowd_control, :max_sessions must be a positive integer, got: #{inspect(other)}"
    end
  end
end
