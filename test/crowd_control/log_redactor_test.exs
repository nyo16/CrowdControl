defmodule CrowdControl.LogRedactorTest do
  # Pure: builds the log events OTP would emit and runs the filter directly. No
  # logger reconfiguration, so this cannot race another test's capture_log.
  use ExUnit.Case, async: true

  alias CrowdControl.LogRedactor

  @redacted :redacted_by_crowd_control

  # The shape OTP actually produces, confirmed by installing a probe filter
  # against a live failed upgrade: keys [:label, :name, :reason, :log, :state,
  # :client_info, :last_message, :process_label].
  defp gen_server_report(last_message, extra \\ %{}) do
    report =
      Map.merge(
        %{
          label: {:gen_server, :terminate},
          name: self(),
          reason: %Mint.TransportError{reason: :econnrefused},
          last_message: last_message,
          state: :some_state,
          client_info: :undefined
        },
        extra
      )

    %{msg: {:report, report}, level: :error, meta: %{}}
  end

  # The cast kubereq 0.4.5 leaves in the mailbox: the whole request, whose
  # `:options` carry the kubeconfig.
  defp leaky_cast(secret) do
    request = %Req.Request{
      method: :get,
      options: %{
        kubeconfig: %{current_user: %{"token" => secret}},
        connect_options: [transport_opts: [cert: <<48, 130, 1, 144>>]]
      }
    }

    {:"$gen_cast", {:request, request}}
  end

  describe "a crash carrying a request (blocker: a kubeconfig in an error line)" do
    test "the request, the state and the client info are replaced" do
      event = gen_server_report(leaky_cast("SECRET-SERVICE-ACCOUNT-TOKEN"))

      assert %{msg: {:report, report}} = LogRedactor.filter(event, [])

      assert report.last_message == @redacted
      assert report.state == @redacted
      assert report.client_info == @redacted
    end

    test "nothing about the secret survives an inspect of the whole event" do
      # The real test is not which keys were touched but whether the credential
      # can still be reached from the event by any path a formatter might take.
      event = gen_server_report(leaky_cast("SECRET-SERVICE-ACCOUNT-TOKEN"))

      dumped = inspect(LogRedactor.filter(event, []), limit: :infinity)

      refute dumped =~ "SECRET-SERVICE-ACCOUNT-TOKEN"
      refute dumped =~ "Req.Request"
      refute dumped =~ "cert"
      refute dumped =~ "kubeconfig"
    end

    test "the diagnosis survives, because a silent crash is a worse bargain" do
      event = gen_server_report(leaky_cast("tok"))

      assert %{msg: {:report, report}} = LogRedactor.filter(event, [])

      # The reason is the part an operator acts on, and it is never a request.
      assert report.reason == %Mint.TransportError{reason: :econnrefused}
      assert report.label == {:gen_server, :terminate}
      assert report.name == self()
    end

    test "a proc_lib crash report is scrubbed too, not just the gen_server one" do
      # Every abnormal exit produces both; redacting one would leave the other
      # printing the same term.
      inner = [
        {:initial_call, {Kubereq.Connect, :init, 1}},
        {:error_info, {:stop, %Mint.TransportError{reason: :closed}, []}},
        {:message_queue, [leaky_cast("SECRET-TOKEN")]}
      ]

      event = %{
        msg: {:report, %{label: {:proc_lib, :crash}, report: [inner, []]}},
        level: :error,
        meta: %{}
      }

      dumped = inspect(LogRedactor.filter(event, []), limit: :infinity)

      refute dumped =~ "SECRET-TOKEN"
      refute dumped =~ "Req.Request"
      # And the call that failed is still named.
      assert dumped =~ "Kubereq.Connect"
    end

    test "a Kubereq.Connect state is redacted even with no request in the mailbox" do
      # The connection struct holds the Mint connection, and through it the
      # socket and the transport options.
      state = %{__struct__: Kubereq.Connect, mint: :fake_conn, req: :fake}
      event = gen_server_report(:some_other_message, %{state: state})

      assert %{msg: {:report, report}} = LogRedactor.filter(event, [])
      assert report.state == @redacted
    end
  end

  describe "everything else passes through (blocker: a filter that eats other libraries' crashes)" do
    test "an unrelated GenServer crash is returned untouched" do
      # This is the risk a global filter carries, and it is the reason the match
      # is on the presence of a request rather than on the label.
      event = gen_server_report({:"$gen_call", {self(), :tag}, :some_business_request})

      assert LogRedactor.filter(event, []) == event
    end

    test "an ordinary string log message is returned untouched" do
      event = %{msg: {:string, "just a log line"}, level: :info, meta: %{}}

      assert LogRedactor.filter(event, []) == event
    end

    test "a format-string report is returned untouched" do
      event = %{msg: {~c"~p failed", [:something]}, level: :error, meta: %{}}

      assert LogRedactor.filter(event, []) == event
    end

    test "the filter never returns :stop, so no crash is ever suppressed" do
      for event <- [
            gen_server_report(leaky_cast("tok")),
            gen_server_report(:unrelated),
            %{msg: {:string, "x"}, level: :info, meta: %{}}
          ] do
        refute LogRedactor.filter(event, []) == :stop
        assert is_map(LogRedactor.filter(event, []))
      end
    end

    test "a deeply nested request beyond the depth bound does not hang or raise" do
      # The walk is depth-bounded on purpose: a filter must never become the
      # expensive part of a crash. Something buried deeper is simply not found,
      # which is a miss rather than a failure.
      deep = Enum.reduce(1..40, %Req.Request{}, fn _, acc -> %{nested: acc} end)
      event = gen_server_report(deep)

      assert %{msg: {:report, _}} = LogRedactor.filter(event, [])
    end
  end

  describe "install/0" do
    test "is a no-op when disabled, and idempotent when enabled" do
      # Installing twice must not accumulate filters — a release that restarts
      # the application would otherwise stack them.
      previous = Application.get_env(:crowd_control, :redact_logs)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:crowd_control, :redact_logs),
          else: Application.put_env(:crowd_control, :redact_logs, previous)
      end)

      Application.put_env(:crowd_control, :redact_logs, false)
      assert LogRedactor.install() == :ok

      Application.put_env(:crowd_control, :redact_logs, true)
      assert LogRedactor.install() == :ok
      assert LogRedactor.install() == :ok
    end
  end
end
