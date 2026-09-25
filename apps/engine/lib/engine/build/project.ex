defmodule Engine.Build.Project do
  alias Engine.Build
  alias Engine.Build.Isolation
  alias Engine.Module.Loader
  alias Engine.Progress
  alias Forge.Internet
  alias Forge.Project

  require Logger

  def compile(%Project{kind: :mix} = project, initial?, force?) do
    Engine.Mix.reload_project(project, fn loaded ->
      with_progress("Building #{Project.display_name(loaded)}", fn token ->
        do_compile(loaded, initial?, force?, token)
      end)
    end)
  end

  def compile(%Project{}, _initial?, _force?) do
    :ok
  end

  def fetch_deps(%Project{kind: :mix} = project) do
    result =
      Engine.Mix.reload_project(project, fn loaded ->
        Logger.info("Fetching dependencies for #{Project.display_name(project)}")

        with_progress(
          "Fetching dependencies for #{Project.display_name(project)}",
          fn token ->
            prepare_for_project_build(token)
            Engine.Mix.record_deps(loaded)
            {:ok, []}
          end
        )
      end)

    case result do
      {:ok, _diagnostics} -> :ok
      error -> error
    end
  end

  def fetch_deps(%Project{}) do
    :ok
  end

  defp with_progress(message, fun) do
    Progress.with_progress(message, fn token ->
      Build.set_progress_token(token)

      try do
        {:done, fun.(token)}
      after
        Build.clear_progress_token()
      end
    end)
  end

  defp do_compile(project, initial?, force?, token) do
    Mix.Task.clear()

    case Isolation.with_diagnostics(Project.mix_exs_path(project), fn ->
           if initial?, do: prepare_for_project_build(token)

           Engine.Mix.record_deps(project)
           Mix.Task.clear()
           Progress.report(token, message: "Compiling #{Project.display_name(project)}")
           result = Mix.Task.run(:compile, Build.State.mix_compile_opts(force?))
           Engine.Mix.ensure_hex_and_rebar()
           Mix.Task.run(:loadpaths)
           result
         end) do
      {:ok, {status, diagnostics}, captured} when status in [:ok, :noop, :error] ->
        maybe_load_modules()
        status = if status == :error, do: :error, else: :ok
        diagnostics = Build.Error.refine_diagnostics(diagnostics)
        {status, captured ++ diagnostics}

      {:error, diagnostics} ->
        {:error, diagnostics}
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

    if not Elixir.Features.compile_keeps_current_directory?() do
      Progress.report(token, message: "mix deps.compile")
      Mix.Task.run("deps.safe_compile", ~w(--skip-umbrella-children))
    end
  end
end
