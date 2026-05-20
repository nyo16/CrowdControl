# Use an MCP config file and constrain the session to a specific
# allowlist of tools.
#
#   mix run examples/custom_mcp.exs
#
# Expects an MCP config at the path below. See:
# https://docs.claude.com/en/docs/claude-code/mcp

mcp_path = Path.expand("./mcp/example.json", __DIR__)

unless File.regular?(mcp_path) do
  IO.puts(:stderr, "Create #{mcp_path} first — see Claude Code docs for the schema.")
  System.halt(1)
end

result =
  CrowdControl.run(
    "List the files this MCP server exposes.",
    model: "sonnet",
    mcp_config: mcp_path,
    strict_mcp_config: true,
    allowed_tools: ["mcp__example__*"],
    api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
    timeout: 60_000
  )

case result do
  {:result, _, %{"result" => text}} -> IO.puts(text)
  {:error, reason} -> IO.puts(:stderr, "error: #{inspect(reason)}")
end
