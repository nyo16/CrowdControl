defmodule CrowdControl.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    max_sessions = Application.get_env(:crowd_control, :max_sessions, 50)

    children = [
      {DynamicSupervisor,
       name: CrowdControl.SessionSupervisor, strategy: :one_for_one, max_children: max_sessions}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
