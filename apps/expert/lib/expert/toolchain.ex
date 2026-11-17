defmodule Expert.Toolchain do
  @moduledoc """
  Provides modules from the project's Elixir and Erlang/OTP installation.

  Expert finds these modules with the project's `elixir` executable. It reads
  BEAM data on demand and caches the data for the session.
  """

  alias Expert.Search.Indexer.BeamFile
  alias Expert.Search.Indexer.Beams
  alias Expert.Search.Subject
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  @probe ~S|IO.write([:code.lib_dir(:elixir), "\n", :code.root_dir()])|

  @type module_info :: %{
          beam_path: Path.t(),
          application: String.t(),
          exports: BeamFile.exports(),
          summary: String.t() | nil
        }

  @doc """
  Returns the names of the toolchain modules, as `Expert.Search.Subject`
  writes them, that start with `prefix`.
  """
  @spec modules_with_prefix(Project.t(), String.t()) :: [String.t()]
  def modules_with_prefix(%Project{} = project, prefix) do
    for {name, _beam} <- modules(project).names, String.starts_with?(name, prefix), do: name
  end

  @doc """
  Returns a toolchain module's BEAM path, application, exports and summary.
  """
  @spec module(Project.t(), String.t()) :: {:ok, module_info()} | :error
  def module(%Project{} = project, name) do
    with {:ok, {beam_path, application}} <- Map.fetch(modules(project).beams, name) do
      cached({:module, beam_path}, fn ->
        with {:ok, beam} <- Expert.File.read(beam_path),
             {:ok, _module, exports, _debug_info} <- BeamFile.read(beam) do
          {:ok,
           %{
             beam_path: beam_path,
             application: application,
             exports: exports,
             summary: Beams.module_summary(beam_path)
           }}
        else
          _ -> :error
        end
      end)
    end
  end

  @doc """
  Returns a toolchain module's public function and macro definitions.
  """
  @spec definitions(Project.t(), String.t()) :: [Entry.t()]
  def definitions(%Project{} = project, name) do
    case Map.fetch(modules(project).beams, name) do
      {:ok, {beam_path, _application}} ->
        cached({:definitions, beam_path}, fn -> Beams.definitions(beam_path) end)

      :error ->
        []
    end
  end

  # The parent of each `ebin` directory supplies the application name.
  defp modules(project) do
    cached({:modules, Project.root_path(project)}, fn ->
      beams =
        for ebin_dir <- ebin_dirs(project),
            application =
              ebin_dir |> Path.dirname() |> Path.basename() |> String.split("-") |> hd(),
            beam_path <- Path.wildcard(Path.join(ebin_dir, "*.beam")),
            into: %{},
            do:
              {beam_path |> Path.basename(".beam") |> Subject.module(), {beam_path, application}}

      %{beams: beams, names: Enum.sort(beams)}
    end)
  end

  defp cached(key, read) do
    key = {__MODULE__, key}

    case :persistent_term.get(key, nil) do
      nil ->
        value = read.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  defp ebin_dirs(project) do
    with {:ok, elixir, env} <- Expert.Port.project_executable(project, "elixir"),
         {output, 0} <-
           System.cmd(to_string(elixir), ["--eval", @probe],
             env: env,
             cd: Project.root_path(project),
             stderr_to_stdout: true
           ),
         [elixir_lib, otp_root] <- String.split(output, "\n") do
      Path.wildcard(Path.join([Path.dirname(elixir_lib), "*", "ebin"])) ++
        Path.wildcard(Path.join([otp_root, "lib", "*", "ebin"]))
    else
      _ -> []
    end
  end
end
