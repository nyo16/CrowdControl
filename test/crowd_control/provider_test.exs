defmodule CrowdControl.ProviderTest do
  # Pure tests for the Provider behaviour's own helpers. No substrate is
  # touched, so these run in the default suite.
  use ExUnit.Case, async: false

  alias CrowdControl.Provider
  alias CrowdControl.Provider.Endpoint

  doctest CrowdControl.Provider

  describe "resolve/1 (blocker: a guessed provider)" do
    test "accepts a bare module and strips :provider from the opts" do
      assert {Provider.Docker, [timeout: 5]} =
               Provider.resolve(provider: Provider.Docker, timeout: 5)
    end

    test "merges {module, config} config over the backend opts" do
      assert {Provider.Docker, opts} =
               Provider.resolve(
                 provider: {Provider.Docker, image: "b", timeout: 9},
                 image: "a",
                 timeout: 1
               )

      assert opts[:image] == "b"
      assert opts[:timeout] == 9
    end

    test "refuses to default: a provider decides where untrusted code runs" do
      # Backend.resolve/1 defaults to Backend.Local because a local subprocess
      # is the status quo. There is no equivalent status quo for a substrate,
      # and inferring one would silently pick an isolation posture.
      assert_raise ArgumentError, ~r/:provider is required/, fn ->
        Provider.resolve([])
      end
    end

    test "rejects anything that is not a module or {module, keyword}" do
      assert_raise ArgumentError, ~r/must be a module/, fn ->
        Provider.resolve(provider: "Elixir.Nope")
      end

      assert_raise ArgumentError, ~r/must be a module/, fn ->
        Provider.resolve(provider: {Provider.Docker, %{not: :keyword}})
      end
    end
  end

  describe "token/1 (blocker: a live credential at rest)" do
    setup do
      previous = Application.get_env(:crowd_control, :sandboxd_secret)

      Application.put_env(
        :crowd_control,
        :sandboxd_secret,
        "test-secret-at-least-32-bytes-long!!"
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:crowd_control, :sandboxd_secret, previous)
        else
          Application.delete_env(:crowd_control, :sandboxd_secret)
        end
      end)
    end

    test "is deterministic for a session key, so reattach can re-derive it" do
      key = CrowdControl.Store.new_key()
      assert Provider.token(key) == Provider.token(key)
    end

    test "differs per session key, so one sandbox's token opens no other" do
      refute Provider.token("aaaa") == Provider.token("bbbb")
    end

    test "is url-safe and unpadded, because it rides in an HTTP header" do
      token = Provider.token("aaaa")
      assert token =~ ~r/^[A-Za-z0-9_-]+$/
      refute String.contains?(token, "=")
    end

    test "changes when the secret rotates, which is what fails reattach closed" do
      before = Provider.token("aaaa")
      Application.put_env(:crowd_control, :sandboxd_secret, "a-different-secret-32-bytes-min!!!!")
      refute Provider.token("aaaa") == before
    end
  end

  describe "token/1 without a configured secret (blocker: a per-boot secret)" do
    test "raises rather than generating one" do
      previous = Application.get_env(:crowd_control, :sandboxd_secret)
      Application.delete_env(:crowd_control, :sandboxd_secret)

      on_exit(fn ->
        previous && Application.put_env(:crowd_control, :sandboxd_secret, previous)
      end)

      # A generated-per-boot secret would work perfectly until the first node
      # restart, then invalidate every persisted session with a 401.
      assert_raise ArgumentError, ~r/:sandboxd_secret is not configured/, fn ->
        Provider.token("aaaa")
      end
    end
  end

  describe "optional callback dispatch" do
    test "age_ms/2 returns nil for a provider that defines none" do
      assert Provider.age_ms(__MODULE__.NoOptional, :handle) == nil
    end

    test "scrub/2 returns the handle untouched for a provider that defines none" do
      assert Provider.scrub(__MODULE__.NoOptional, {:handle, "keep"}) == {:handle, "keep"}
    end

    test "age_ms/2 and scrub/2 dispatch when the provider defines them" do
      assert Provider.age_ms(__MODULE__.WithOptional, :handle) == 42
      assert Provider.scrub(__MODULE__.WithOptional, %{token: "secret", id: "x"}) == %{id: "x"}
    end
  end

  describe "Endpoint redaction (blocker: a token in a log line)" do
    test "inspect hides the token" do
      endpoint = %Endpoint{base_url: "http://127.0.0.1:32768", token: "super-secret-token"}
      dumped = inspect(endpoint)

      refute dumped =~ "super-secret-token"
      assert dumped =~ "[REDACTED]"
      assert dumped =~ "127.0.0.1:32768"
    end

    test "inspect hides header values but keeps their names" do
      endpoint = %Endpoint{
        base_url: "http://127.0.0.1:1",
        token: "t",
        headers: [{"authorization", "Bearer apiserver-credential"}]
      }

      dumped = inspect(endpoint)

      refute dumped =~ "apiserver-credential"
      assert dumped =~ "authorization"
    end

    test "inspect keeps req_options names but not their values" do
      endpoint = %Endpoint{
        base_url: "http://127.0.0.1:1",
        token: "t",
        req_options: [connect_options: [transport_opts: [cacerts: :sensitive]]]
      }

      dumped = inspect(endpoint)

      assert dumped =~ "connect_options"
      refute dumped =~ "sensitive"
    end

    test "base_url and token are both required" do
      assert_raise ArgumentError, fn -> struct!(Endpoint, base_url: "http://x") end
    end
  end

  defmodule NoOptional do
    @moduledoc false
    @behaviour CrowdControl.Provider

    @impl true
    def acquire(_opts), do: {:error, :not_implemented}
    @impl true
    def reconnect(_handle), do: {:error, :not_implemented}
    @impl true
    def release(_handle), do: :ok
    @impl true
    def list_live(_opts), do: {:ok, []}
  end

  defmodule WithOptional do
    @moduledoc false
    @behaviour CrowdControl.Provider

    @impl true
    def acquire(_opts), do: {:error, :not_implemented}
    @impl true
    def reconnect(_handle), do: {:error, :not_implemented}
    @impl true
    def release(_handle), do: :ok
    @impl true
    def list_live(_opts), do: {:ok, []}
    @impl true
    def age_ms(_handle), do: 42
    @impl true
    def scrub(handle), do: Map.delete(handle, :token)
  end
end
