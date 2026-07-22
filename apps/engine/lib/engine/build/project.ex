defmodule Engine.Build.Project do
  alias Engine.Build
  alias Engine.Build.Isolation
  alias Engine.Module.Loader
  alias Engine.Progress
  alias Forge.Internet
  alias Forge.Project
  alias Mix.Task.Compiler.Diagnostic

  require Logger

  def compile(%Project{kind: :mix} = project, initial?, force?) do
    Engine.Mix.in_project(fn _ ->
      Logger.info("Building #{Project.display_name(project)}")

      Progress.with_progress("Building #{Project.display_name(project)}", fn token ->
        Build.set_progress_token(token)

        try do
          {:done, do_compile(project, initial?, force?, token)}
        after
          Build.clear_progress_token()
        end
      end)
    end)
  end

  def compile(%Project{}, _initial?, _force?) do
    case Engine.Mix.take_initial_project_diagnostics() do
      [] -> :ok
      diagnostics -> {:error, diagnostics}
    end
  end

  def fetch_deps(%Project{kind: :mix} = project) do
    Engine.Mix.in_project(project, fn _ ->
      Logger.info("Fetching dependencies for #{Project.display_name(project)}")

      Progress.with_progress(
        "Fetching dependencies for #{Project.display_name(project)}",
        fn token ->
          Build.set_progress_token(token)

          try do
            prepare_for_project_build(token)
            Engine.Mix.record_deps(project)
            {:done, :ok}
          after
            Build.clear_progress_token()
          end
        end
      )
    end)
  end

  def fetch_deps(%Project{}) do
    :ok
  end

  defp do_compile(project, initial?, force?, token) do
    Mix.Task.clear()

    if initial? do
      prepare_for_project_build(token)
    end

    Engine.Mix.record_deps(project)

    compile_fun = fn ->
      Mix.Task.clear()
      Progress.report(token, message: "Compiling #{Project.display_name(project)}")
      result = compile_in_isolation(force?)
      maybe_load_modules()
      Engine.Mix.ensure_hex_and_rebar()
      Mix.Task.run(:loadpaths)
      result
    end

    case compile_fun.() do
      {:error, diagnostics} ->
        diagnostics =
          diagnostics
          |> List.wrap()
          |> Build.Error.refine_diagnostics()

        {:error, diagnostics}

      {status, diagnostics} when status in [:ok, :noop] ->
        Logger.info(
          "Compile completed with status #{status} " <>
            "Produced #{length(diagnostics)} diagnostics " <>
            inspect(diagnostics)
        )

        Build.Error.refine_diagnostics(diagnostics)
    end
  end

  def maybe_load_modules do
    if Elixir.Features.lazy_loading?() do
      modules_to_load =
        for {mod, _, false} <- :code.all_available() do
          List.to_atom(mod)
        end

      Logger.info("Loading #{length(modules_to_load)} modules")
      Loader.load_all(modules_to_load)
    end
  end

  defp compile_in_isolation(force?) do
    compile_fun = fn ->
      Engine.Mix.ensure_hex_and_rebar()
      Mix.Task.run(:compile, Build.State.mix_compile_opts(force?))
    end

    case Isolation.invoke(compile_fun) do
      {:ok, result} ->
        result

      {:error, {exception, [{_mod, _fun, _arity, meta} | _]}} ->
        diagnostic = %Diagnostic{
          file: Keyword.get(meta, :file),
          severity: :error,
          message: Exception.message(exception),
          compiler_name: "Elixir",
          position: Keyword.get(meta, :line, 1)
        }

        {:error, [diagnostic]}
    end
  end

  defp prepare_for_project_build(token) do
    if Internet.connected_to_internet?() do
      Progress.report(token, message: "mix local.hex")
      Mix.Task.run("local.hex", ~w(--force --if-missing))

      Progress.report(token, message: "mix local.rebar")
      Mix.Task.run("local.rebar", ~w(--force --if-missing))

      Progress.report(token, message: "mix deps.get")
      Mix.Task.run("deps.get")
    else
      Logger.warning("Could not connect to hex.pm, dependencies will not be fetched")
    end

    Progress.report(token, message: "mix loadconfig")
    Mix.Task.run(:loadconfig)

    if not Elixir.Features.compile_keeps_current_directory?() do
      Progress.report(token, message: "mix deps.compile")
      Mix.Task.run("deps.safe_compile", ~w(--skip-umbrella-children))
    end
  end
end
