defmodule CrowdControl.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Before anything can fail: a rejected exec upgrade makes kubereq's
    # connection process crash with the whole %Req.Request{} — kubeconfig
    # included — as its last message. See CrowdControl.LogRedactor.
    :ok = CrowdControl.LogRedactor.install()

    max_sessions = fetch_max_sessions!()
    {store, store_opts} = CrowdControl.Store.resolve()

    # Order matters. The store must be up before any session can persist to it,
    # and the reaper comes last because its boot reconciliation starts sessions
    # under the session supervisor.
    children = [
      {store, store_opts},
      {DynamicSupervisor,
       name: CrowdControl.SessionSupervisor, strategy: :one_for_one, max_children: max_sessions},
      CrowdControl.Reaper
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
