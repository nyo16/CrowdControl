# CrowdControl

Orchestrate many Claude Code / Open Code CLI instances in parallel from Elixir.

Built on [net_runner](https://hex.pm/packages/net_runner) for zero-zombie subprocess management with NIF-based backpressure.

## Installation

```elixir
def deps do
  [
    {:crowd_control, "~> 0.1.0"}
  ]
end
```

## Quick Start

### Single session

```elixir
# Fire-and-forget single prompt
result = CrowdControl.run("Explain GenServer in one sentence",
  permission_mode: "bypassPermissions"
)
# => {:result, "success", %{"result" => "GenServer is...", "total_cost_usd" => 0.003}}
```

### Parallel sessions

```elixir
# Run 5 sessions with different prompts
opts_list = Enum.map(1..5, fn i ->
  [prompt: "Write a haiku about the number #{i}", permission_mode: "bypassPermissions"]
end)

{:ok, sessions} = CrowdControl.start_sessions(opts_list)
results = CrowdControl.collect(sessions, 120_000)
CrowdControl.stop_all(sessions)

# results is [{session_pid, {:result, "success", %{...}}}, ...]
```

### Same prompt, different models

```elixir
results = CrowdControl.run_many("What is the meaning of life?", [
  [model: "sonnet", permission_mode: "bypassPermissions"],
  [model: "opus", permission_mode: "bypassPermissions"],
  [model: "haiku", permission_mode: "bypassPermissions"]
])
```

### Multi-turn conversation

```elixir
{:ok, session} = CrowdControl.start_session(
  prompt: "You are a code reviewer. Wait for code to review.",
  permission_mode: "bypassPermissions"
)

CrowdControl.Session.subscribe(session)

# Wait for initial result, then send follow-up
receive do
  {:crowd_control, ^session, {:result, _, _}} -> :ok
end

CrowdControl.Session.send_prompt(session, "Review this: def add(a, b), do: a + b")

receive do
  {:crowd_control, ^session, {:result, _, %{"result" => review}}} ->
    IO.puts(review)
end

CrowdControl.Session.stop(session)
```

### Subscribing to streaming messages

```elixir
{:ok, session} = CrowdControl.start_session(
  prompt: "Write a short poem",
  permission_mode: "bypassPermissions",
  include_partial_messages: true
)

CrowdControl.Session.subscribe(session)

# Receive all messages as they stream
defmodule Listener do
  def loop do
    receive do
      {:crowd_control, _pid, {:system_init, %{"session_id" => sid}}} ->
        IO.puts("Session started: #{sid}")
        loop()

      {:crowd_control, _pid, {:assistant, %{"message" => msg}}} ->
        IO.puts("Assistant: #{inspect(msg["content"])}")
        loop()

      {:crowd_control, _pid, {:result, "success", %{"result" => text}}} ->
        IO.puts("Done: #{text}")

      {:crowd_control, _pid, {:exit, status}} ->
        IO.puts("Exited with status: #{status}")
    after
      30_000 -> IO.puts("Timeout")
    end
  end
end

Listener.loop()
```

### Using Open Code

```elixir
CrowdControl.run("Hello", executable: "open-code", permission_mode: "bypassPermissions")
```

## CLI Options

All options from `CrowdControl.CLI.build_command/1` can be passed to `start_session`, `run`, and `run_many`:

| Option | Description |
|--------|-------------|
| `:executable` | CLI binary name or path (default: `"claude"`) |
| `:prompt` | Initial prompt to send |
| `:model` | Model to use (`"sonnet"`, `"opus"`, `"haiku"`) |
| `:system_prompt` | Custom system prompt |
| `:allowed_tools` | List of allowed tool names |
| `:permission_mode` | Permission mode string |
| `:max_budget_usd` | Spending ceiling |
| `:session_id` | Session ID for new sessions |
| `:resume` | Session ID to resume |
| `:continue` | `true` to continue most recent session |
| `:add_dir` | Additional project directory |
| `:include_partial_messages` | `true` for streaming deltas |
| `:no_session_persistence` | `true` to skip saving to disk |
| `:extra_args` | List of additional CLI arguments |

## Architecture

### Supervision Tree

```mermaid
graph TD
    A[CrowdControl.Application] --> B[DynamicSupervisor<br/>SessionSupervisor]
    B --> C1[Session GenServer #1]
    B --> C2[Session GenServer #2]
    B --> C3[Session GenServer #N]
    C1 --> D1[NetRunner.Process<br/>claude CLI]
    C1 --> E1[Reader Process<br/>stdout drain]
    C2 --> D2[NetRunner.Process<br/>claude CLI]
    C2 --> E2[Reader Process<br/>stdout drain]
    C3 --> D3[NetRunner.Process<br/>open-code CLI]
    C3 --> E3[Reader Process<br/>stdout drain]

    style A fill:#4a9eff,color:#fff
    style B fill:#ff6b6b,color:#fff
    style C1 fill:#51cf66,color:#fff
    style C2 fill:#51cf66,color:#fff
    style C3 fill:#51cf66,color:#fff
    style D1 fill:#ffd43b,color:#333
    style D2 fill:#ffd43b,color:#333
    style D3 fill:#ffd43b,color:#333
    style E1 fill:#cc5de8,color:#fff
    style E2 fill:#cc5de8,color:#fff
    style E3 fill:#cc5de8,color:#fff
```

### Session Lifecycle

```mermaid
stateDiagram-v2
    [*] --> starting: start_link(opts)
    starting --> running: system_init received
    running --> running: assistant / user messages
    running --> completed: result message received
    running --> error: CLI crash / timeout
    starting --> error: spawn failure
    completed --> [*]: stop
    error --> [*]: stop / supervisor restart
```

### Message Flow

```mermaid
sequenceDiagram
    participant Caller
    participant Session as Session GenServer
    participant Reader as Reader Process
    participant NR as NetRunner.Process
    participant CLI as claude CLI

    Caller->>Session: start_session(prompt: "...")
    Session->>NR: start_link("claude", args)
    NR->>CLI: spawn OS process
    Session->>Reader: spawn_link(reader_loop)
    Session->>NR: write(encoded_prompt)
    NR->>CLI: stdin: {"type":"user",...}\n

    CLI->>NR: stdout: {"type":"system","subtype":"init",...}\n
    NR->>Reader: read() → {:ok, data}
    Reader->>Session: cast {:stdout_data, data}
    Session->>Caller: send {:crowd_control, pid, {:system_init, ...}}

    CLI->>NR: stdout: {"type":"assistant",...}\n
    NR->>Reader: read() → {:ok, data}
    Reader->>Session: cast {:stdout_data, data}
    Session->>Caller: send {:crowd_control, pid, {:assistant, ...}}

    CLI->>NR: stdout: {"type":"result","subtype":"success",...}\n
    NR->>Reader: read() → {:ok, data}
    Reader->>Session: cast {:stdout_data, data}
    Session->>Caller: send {:crowd_control, pid, {:result, ...}}
```

### Parallel Execution

```mermaid
graph LR
    A[CrowdControl.run_many] --> B[Task.async_stream]
    B --> S1[Session 1<br/>model: sonnet]
    B --> S2[Session 2<br/>model: opus]
    B --> S3[Session 3<br/>model: haiku]

    S1 --> C1[claude --model sonnet]
    S2 --> C2[claude --model opus]
    S3 --> C3[claude --model haiku]

    C1 --> R[collect results]
    C2 --> R
    C3 --> R
    R --> OUT["{session, {:result, ...}}"]

    style A fill:#4a9eff,color:#fff
    style B fill:#ff6b6b,color:#fff
    style S1 fill:#51cf66,color:#fff
    style S2 fill:#51cf66,color:#fff
    style S3 fill:#51cf66,color:#fff
    style R fill:#ffd43b,color:#333
```

### Wire Protocol (stream-json)

```mermaid
sequenceDiagram
    participant E as Elixir
    participant C as Claude CLI

    Note over E,C: stdin: newline-delimited JSON
    E->>C: {"type":"user","message":{"role":"user","content":"Hello"}}\n

    Note over E,C: stdout: newline-delimited JSON
    C->>E: {"type":"system","subtype":"init","session_id":"..."}\n
    C->>E: {"type":"assistant","message":{"content":[...]}}\n
    C->>E: {"type":"result","subtype":"success","result":"..."}\n

    Note over E,C: Multi-turn: send another prompt after result
    E->>C: {"type":"user","message":{"role":"user","content":"Follow up"}}\n
    C->>E: {"type":"assistant","message":{"content":[...]}}\n
    C->>E: {"type":"result","subtype":"success","result":"..."}\n
```

### Module Dependency

```mermaid
graph BT
    P[Protocol<br/><i>pure functions</i>]
    CLI[CLI<br/><i>pure functions</i>]
    S[Session<br/><i>GenServer</i>] --> P
    S --> CLI
    S --> NR[NetRunner.Process]
    CC[CrowdControl<br/><i>public API</i>] --> S
    CC --> DS[DynamicSupervisor]
    APP[Application] --> DS

    style P fill:#51cf66,color:#fff
    style CLI fill:#51cf66,color:#fff
    style S fill:#4a9eff,color:#fff
    style CC fill:#ff6b6b,color:#fff
    style APP fill:#ffd43b,color:#333
    style NR fill:#cc5de8,color:#fff
    style DS fill:#ffd43b,color:#333
```

### Fault Tolerance

```mermaid
graph TD
    SUP[DynamicSupervisor<br/>one_for_one] -->|supervises| S1[Session 1]
    SUP -->|supervises| S2[Session 2]
    SUP -->|supervises| S3[Session 3]

    S2 -->|crash| X["Session 2 crashes"]
    X -->|restart| S2R[Session 2<br/>restarted]
    SUP -->|supervises| S2R

    S1 -.->|unaffected| S1
    S3 -.->|unaffected| S3

    NR[NetRunner Shepherd] -->|zero zombies| Z["OS process cleanup<br/>guaranteed even on<br/>BEAM crash"]

    style X fill:#ff6b6b,color:#fff
    style S2R fill:#51cf66,color:#fff
    style Z fill:#ffd43b,color:#333
```
