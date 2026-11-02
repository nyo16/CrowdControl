defmodule CrowdControl.Backend.Shell do
  @moduledoc """
  Shell quoting shared by every backend that crosses an `sh -c` boundary.

  This exists as one module, used by every backend, on purpose. `Backend.Local`
  interpolates env values into a sourced env file; `Backend.Docker` interpolates
  prompts into a `printf ... >> fifo` exec. Both carry attacker-influenced input
  across the same boundary, and a second, subtly different escaper is precisely
  how one of them ends up wrong. `test/crowd_control/security_test.exs` is the
  oracle for this function.
  """

  @doc """
  Wrap `value` in single quotes, rendering every byte inside it inert to `sh`.

  Single-quoting is total in POSIX shell — no escape sequence, variable, or
  substitution is interpreted inside `'...'`. The only byte that needs handling
  is `'` itself, which closes the quote; the standard `'\\''` idiom closes,
  emits a literal quote, and reopens.

      iex> CrowdControl.Backend.Shell.escape("plain")
      "'plain'"

      iex> CrowdControl.Backend.Shell.escape("it's")
      "'it'\\\\''s'"

      iex> CrowdControl.Backend.Shell.escape("$(rm -rf /)")
      "'$(rm -rf /)'"
  """
  @spec escape(term()) :: String.t()
  def escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  # The fixed names a release's boot script exports besides `RELEASE_*`
  # (`erts-*/bin/erl` and the generated `bin/<name>` script).
  @release_boot_vars ~w(BINDIR ROOTDIR EMU PROGNAME)

  @doc """
  What to scrub from a child's environment so it does not inherit a release's.

  When CrowdControl runs inside a `mix release`, the BEAM's environment carries
  the release's boot variables: `RELEASE_COOKIE` (the distribution cookie, a
  credential), `RELEASE_ROOT`, `RELEASE_NODE`, `BINDIR`, `ROOTDIR` and the rest,
  plus a `PATH` with the release's `bin` and `erts-*/bin` in front. A CLI
  spawned from that VM inherits all of it.

  Takes the parent's environment (`System.get_env/0`) and returns:

    * the names to `unset`: every `RELEASE_*` name actually present (enumerated
      here, never a shell glob) plus `BINDIR`, `ROOTDIR`, `EMU` and `PROGNAME`
      when present. Names that are not valid shell identifiers are left out,
      because `sh` cannot unset them and they must never be interpolated into a
      script;
    * the `PATH` to export with `RELEASE_ROOT/bin` and `RELEASE_ROOT/erts-*/bin`
      removed, or `nil` when `RELEASE_ROOT` (or `PATH`) is unset and so there is
      no release `PATH` to strip.

  Pure, so `CrowdControl.Backend.Local` and sandboxd's copy of it
  (`Sandboxd.Exec.release_scrub/1`) agree by test rather than by inspection.

      iex> CrowdControl.Backend.Shell.release_scrub(%{
      ...>   "RELEASE_ROOT" => "/app",
      ...>   "RELEASE_COOKIE" => "secret",
      ...>   "BINDIR" => "/app/erts-15.0/bin",
      ...>   "PATH" => "/app/erts-15.0/bin:/app/bin:/usr/bin:/bin",
      ...>   "HOME" => "/root"
      ...> })
      {["BINDIR", "RELEASE_COOKIE", "RELEASE_ROOT"], "/usr/bin:/bin"}

      iex> CrowdControl.Backend.Shell.release_scrub(%{"PATH" => "/usr/bin", "HOME" => "/root"})
      {[], nil}
  """
  @spec release_scrub(%{optional(String.t()) => String.t()}) ::
          {[String.t()], String.t() | nil}
  def release_scrub(env) when is_map(env) do
    unset =
      env
      |> Map.keys()
      |> Enum.filter(&(release_var?(&1) and shell_name?(&1)))
      |> Enum.sort()

    {unset, release_free_path(env)}
  end

  defp release_var?(name),
    do: String.starts_with?(name, "RELEASE_") or name in @release_boot_vars

  defp shell_name?(name), do: name =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  defp release_free_path(%{"RELEASE_ROOT" => root, "PATH" => path})
       when root not in ["", "/"] do
    prefix = String.trim_trailing(root, "/") <> "/"

    path
    |> String.split(":")
    |> Enum.reject(&release_bin?(&1, prefix))
    |> Enum.join(":")
  end

  defp release_free_path(_env), do: nil

  defp release_bin?(entry, prefix) do
    entry = String.trim_trailing(entry, "/")

    String.starts_with?(entry, prefix) and
      String.replace_prefix(entry, prefix, "") =~ ~r{\A(bin|erts-[^/]+/bin)\z}
  end
end
