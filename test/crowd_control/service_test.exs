defmodule CrowdControl.ServiceTest do
  use ExUnit.Case, async: true

  alias CrowdControl.Service

  doctest CrowdControl.Service

  describe "posture is never inferred (blocker: a sidecar quietly weaker than declared)" do
    test "a sidecar must state its egress; the sandbox may never have it" do
      assert {:error, {:egress_required, "p"}} =
               Service.normalize(%{name: "p", image: "i"}, :sidecar)

      assert {:error, :sandbox_egress_forbidden} =
               Service.normalize(%{name: "sandbox", egress: :allow}, :sandbox)

      assert {:error, {:bad_egress, {"p", :maybe}}} =
               Service.normalize(%{name: "p", image: "i", egress: :maybe}, :sidecar)
    end

    test "the sandbox may leave :image for the caller to fill; a sidecar may not" do
      assert {:ok, %Service{image: nil, role: :sandbox}} =
               Service.normalize(%{name: "sandbox"}, :sandbox)

      assert {:error, {:image_required, "p"}} =
               Service.normalize(%{name: "p", egress: :none}, :sidecar)
    end

    test "a non-map spec and a non-DNS name are refused" do
      assert {:error, {:bad_service, [name: "x"]}} = Service.normalize([name: "x"], :sidecar)
      assert {:error, {:bad_service_name, "Bad"}} = Service.normalize(%{name: "Bad"}, :sidecar)
    end

    test "every weakening key must be declared" do
      for {host_config, user, key} <- [
            {%{cap_add: ["NET_ADMIN"]}, nil, :cap_add},
            {%{no_new_privileges: false}, nil, :no_new_privileges},
            {%{readonly_rootfs: false}, nil, :readonly_rootfs},
            {%{}, "0", :user},
            {%{}, "root:root", :user}
          ] do
        spec = sidecar(host_config: host_config) |> maybe_user(user)
        assert {:error, {:weakening_not_declared, {"b", ^key}}} = Service.normalize(spec, :sidecar)

        assert {:ok, %Service{}} = Service.normalize(Map.put(spec, :weaken, [key]), :sidecar)
      end
    end

    test "resource keys and hardening-direction values need no declaration" do
      host_config = %{
        shm_size: 1_073_741_824,
        init: true,
        pids_limit: 1024,
        memory: 2_000_000_000,
        cpus: 1.5,
        tmpfs: %{"/tmp" => "rw,size=512m"},
        no_new_privileges: true,
        readonly_rootfs: true,
        cap_add: []
      }

      assert {:ok, %Service{host_config: ^host_config}} =
               Service.normalize(sidecar(host_config: host_config, user: "1000"), :sidecar)
    end

    test "privileged is refused outright, declared or not" do
      assert {:error, {:privileged_refused, "b"}} =
               Service.normalize(sidecar(host_config: %{privileged: true}), :sidecar)

      assert {:error, {:privileged_refused, "b"}} =
               Service.normalize(sidecar(weaken: [:privileged]), :sidecar)
    end

    test "an unknown or mistyped host_config key is refused rather than ignored" do
      assert {:error, {:bad_host_config, {"b", :network_mode}}} =
               Service.normalize(sidecar(host_config: %{network_mode: "host"}), :sidecar)

      assert {:error, {:bad_host_config, {"b", :shm_size}}} =
               Service.normalize(sidecar(host_config: %{shm_size: "1g"}), :sidecar)

      assert {:error, {:bad_service, {"b", :weaken}}} =
               Service.normalize(sidecar(weaken: [:everything]), :sidecar)
    end
  end

  describe "fields" do
    test "the legacy :port leads :ports" do
      assert {:ok, %Service{ports: [3128, 9000]}} =
               Service.normalize(sidecar(port: 3128, ports: [9000, 3128]), :sidecar)

      assert {:error, {:bad_service, {"b", :ports}}} =
               Service.normalize(sidecar(ports: [0]), :sidecar)
    end

    test "volumes use CrowdControl.Volume's shape" do
      assert {:ok, %Service{volumes: [%{kind: :volume, source: "c", target: "/c"}]}} =
               Service.normalize(sidecar(volumes: [%{name: "c", target: "/c"}]), :sidecar)

      assert {:error, {:bad_mount, {"b", %{name: "c", target: "rel"}}}} =
               Service.normalize(sidecar(volumes: [%{name: "c", target: "rel"}]), :sidecar)
    end

    test "networks default to sbx and must be a non-empty unique list" do
      {:ok, plain} = Service.normalize(sidecar([]), :sidecar)
      assert plain.networks == nil
      assert Service.networks(plain) == ["sbx"]

      for bad <- [[], ["a", "a"], ["Bad"], "sbx"] do
        assert {:error, {:bad_service, {"b", :networks}}} =
                 Service.normalize(sidecar(networks: bad), :sidecar)
      end
    end

    test "placement accepts the Kubernetes vocabulary only" do
      for placement <- [:pod, :separate, {:external, %{ip_block: "10.0.0.0/8"}}] do
        assert {:ok, %Service{placement: ^placement}} =
                 Service.normalize(sidecar(placement: placement), :sidecar)
      end

      assert {:error, {:bad_service, {"b", :placement}}} =
               Service.normalize(sidecar(placement: :anywhere), :sidecar)
    end

    test "ready takes a Docker test, a tcp port, or both" do
      assert {:ok, _} = Service.normalize(sidecar(ready: %{test: ["CMD", "true"]}), :sidecar)
      assert {:ok, _} = Service.normalize(sidecar(ready: %{tcp_port: 8931}), :sidecar)

      for bad <- [%{}, %{test: ["NONE"]}, %{tcp_port: 0}, :yes] do
        assert {:error, {:bad_ready, "b"}} = Service.normalize(sidecar(ready: bad), :sidecar)
      end
    end

    test "drain defaults its shutdown limit and budgets a stop timeout past it" do
      {:ok, svc} = Service.normalize(sidecar(drain: 3_000), :sidecar)

      assert svc.shutdown_limit == 20
      assert Service.drained?(svc)
      assert Service.drain_seconds(svc) == 3
      assert Service.stop_timeout(svc) == 25

      assert {:error, {:bad_service, {"b", :shutdown_limit}}} =
               Service.normalize(sidecar(shutdown_limit: 5), :sidecar)

      assert {:error, {:bad_service, {"b", :drain}}} =
               Service.normalize(sidecar(drain: -1), :sidecar)
    end
  end

  describe ":files validation (blocker: a tar entry that climbs out of its root)" do
    test "paths must be absolute and free of dot segments" do
      for path <- ["rel/a", "/a/../b", "/a/./b", "/a//b", "/", "/a/", "/a\0b", nil] do
        assert {:error, {:bad_file, {"b", ^path}}} =
                 Service.validate_files([%{path: path, content: "x"}], "b")
      end
    end

    test "paths are unique" do
      files = [%{path: "/a", content: "1"}, %{path: "/a", content: "2"}]
      assert {:error, {:duplicate_file, {"b", "/a"}}} = Service.validate_files(files, "b")
    end

    test "all content together is at most 1 MiB" do
      half = :binary.copy("x", div(Service.max_files_bytes(), 2))

      assert {:ok, _} =
               Service.validate_files(
                 [%{path: "/a", content: half}, %{path: "/b", content: half}],
                 "b"
               )

      assert {:error, {:files_too_large, {"b", size}}} =
               Service.validate_files(
                 [%{path: "/a", content: half}, %{path: "/b", content: half <> "x"}],
                 "b"
               )

      assert size == Service.max_files_bytes() + 1
    end

    test "mode, uid and gid are validated and defaulted" do
      assert {:ok, [%{mode: 0o600, uid: 65_532, gid: 0}]} =
               Service.validate_files([%{path: "/a", content: "", mode: 0o600, uid: 65_532}], "b")

      assert {:error, {:bad_file, {"b", "/a"}}} =
               Service.validate_files([%{path: "/a", content: "", mode: 0o10000}], "b")

      assert {:error, {:bad_file, {"b", "/a"}}} =
               Service.validate_files([%{path: "/a", content: :atom}], "b")

      assert {:error, {:bad_service, {"b", :files}}} = Service.validate_files("nope", "b")
    end
  end

  defp sidecar(extra), do: Map.merge(%{name: "b", image: "i", egress: :none}, Map.new(extra))

  defp maybe_user(spec, nil), do: spec
  defp maybe_user(spec, user), do: Map.put(spec, :user, user)
end
