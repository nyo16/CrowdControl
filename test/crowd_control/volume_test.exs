defmodule CrowdControl.VolumeTest do
  # Pure: the shared mount contract, with no substrate involved.
  use ExUnit.Case, async: true

  alias CrowdControl.Volume

  doctest CrowdControl.Volume

  @reserved ["/var/run/cc.fifo", "/var/log/cc/out.jsonl", "/var/run/cc.env"]

  describe "the shape every substrate accepts" do
    test "absent, empty and nil all mean no mounts" do
      # Threaded unconditionally by three call sites, so "not asking for
      # volumes" must not be an error.
      assert Volume.normalize([], @reserved) == {:ok, []}
      assert Volume.normalize([volumes: []], @reserved) == {:ok, []}
      assert Volume.normalize([volumes: nil], @reserved) == {:ok, []}
    end

    test "a named volume and a host path normalize to the same struct" do
      assert {:ok, [named, host]} =
               Volume.normalize(
                 [
                   volumes: [
                     %{name: "workspace", target: "/workspace"},
                     %{host_path: "/srv/fixtures", target: "/fixtures", read_only: true}
                   ]
                 ],
                 @reserved
               )

      assert named == %{
               kind: :volume,
               source: "workspace",
               target: "/workspace",
               read_only: false
             }

      assert host == %{
               kind: :host_path,
               source: "/srv/fixtures",
               target: "/fixtures",
               read_only: true
             }
    end

    test "read_only defaults to false and only `true` enables it" do
      # Not truthiness: `read_only: "yes"` meaning writable is surprising, but
      # less surprising than a string silently meaning read-only.
      for value <- [nil, false, "true", 1] do
        spec = %{name: "v", target: "/v", read_only: value}
        assert {:ok, [%{read_only: false}]} = Volume.normalize([volumes: [spec]], [])
      end

      assert {:ok, [%{read_only: true}]} =
               Volume.normalize([volumes: [%{name: "v", target: "/v", read_only: true}]], [])
    end
  end

  describe "refusals (blocker: a mount that breaks the transport or the host)" do
    test "a source is required and only one of them" do
      assert {:error, {:invalid_volume, _, :source_required}} =
               Volume.normalize([volumes: [%{target: "/w"}]], [])

      # Both keys means the caller has two different mental models of what this
      # mount is; guessing which one they meant is worse than asking.
      assert {:error, {:invalid_volume, _, :ambiguous_source}} =
               Volume.normalize([volumes: [%{name: "v", host_path: "/h", target: "/w"}]], [])
    end

    test "relative paths are refused on both sides" do
      # The Docker CLI resolves a relative bind against the shell's cwd; the
      # Engine API and Kubernetes do not resolve it at all. Three substrates
      # would disagree, so none of them get the chance.
      assert {:error, {:invalid_volume, _, {:host_path_not_absolute, "./data"}}} =
               Volume.normalize([volumes: [%{host_path: "./data", target: "/data"}]], [])

      assert {:error, {:invalid_volume, _, {:target_not_absolute, "data"}}} =
               Volume.normalize([volumes: [%{name: "v", target: "data"}]], [])
    end

    test "the transport's own paths cannot be mounted over" do
      # Mounting the FIFO does not fail loudly: the sandbox starts, the CLI
      # blocks on a FIFO nobody writes, and the reader delivers nothing. That
      # is a support ticket, so it is refused here.
      for target <- @reserved do
        assert {:error, {:invalid_volume, _, {:reserved_target, ^target}}} =
                 Volume.normalize([volumes: [%{name: "v", target: target}]], @reserved)
      end
    end

    test "mounting a directory that holds a transport path is the same mistake" do
      # /var/run hides /var/run/cc.fifo just as completely.
      assert {:error, {:invalid_volume, _, {:reserved_target, "/var/run"}}} =
               Volume.normalize([volumes: [%{name: "v", target: "/var/run"}]], @reserved)

      assert {:error, {:invalid_volume, _, {:reserved_target, "/var/log/cc"}}} =
               Volume.normalize([volumes: [%{name: "v", target: "/var/log/cc"}]], @reserved)
    end

    test "a sibling that merely shares a prefix string is allowed" do
      # The check is on path segments, not on String.starts_with?/2, or
      # /var/log/cc2 would be refused for looking like /var/log/cc.
      assert {:ok, [%{target: "/var/log/cc2"}]} =
               Volume.normalize([volumes: [%{name: "v", target: "/var/log/cc2"}]], @reserved)

      assert {:ok, [%{target: "/var/running"}]} =
               Volume.normalize([volumes: [%{name: "v", target: "/var/running"}]], @reserved)
    end

    test "two mounts cannot claim the same target" do
      # Docker takes the last one and Kubernetes rejects the Pod, so the same
      # config would behave differently per substrate.
      assert {:error, {:invalid_volume, _, {:duplicate_target, "/w"}}} =
               Volume.normalize(
                 [volumes: [%{name: "a", target: "/w"}, %{name: "b", target: "/w"}]],
                 []
               )
    end

    test "the container of the whole option is checked too" do
      assert {:error, {:invalid_volumes, "workspace:/workspace"}} =
               Volume.normalize([volumes: "workspace:/workspace"], [])

      assert {:error, {:invalid_volume, "x", :not_a_map}} =
               Volume.normalize([volumes: ["x"]], [])
    end
  end

  describe "normalize!/2" do
    test "returns the mounts a valid option list describes" do
      assert [%{target: "/w"}] = Volume.normalize!([volumes: [%{name: "v", target: "/w"}]], [])
    end

    test "raises with the reason, because reaching it means provisioning skipped the gate" do
      assert_raise ArgumentError, ~r/invalid :volumes.*source_required/, fn ->
        Volume.normalize!([volumes: [%{target: "/w"}]], [])
      end
    end
  end
end
