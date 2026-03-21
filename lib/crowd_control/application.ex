defmodule CrowdControl.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: CrowdControl.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
