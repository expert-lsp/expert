defmodule Engine.Mix do
  alias Forge.Project

  def loaded? do
    not is_nil(Mix.Project.get())
  end

  def in_project(fun) do
    if Engine.project_node?() do
      in_project(Engine.get_project(), fun)
    else
      {:error, :not_project_node}
    end
  end

  def in_project(%Project{} = project, fun) do
    # Locking on the build make sure we don't get a conflict on the mix.exs being
    # already defined

    old_cwd = File.cwd!()
    project_root = Project.root_path(project)
    build_path = Project.versioned_build_path(project)
    app = Project.atom_name(project)
    file = Project.mix_exs_path(project)

    # We bypass Mix.Project.in_project/4 so we can release
    # Engine.Mix.StackMutation between push and fun, allowing other callers
    # (Format, Quoted.prepare_compile) to mutate the stack while fun runs.

    with_lock(fn ->
      try do
        File.cd!(project_root)

        Engine.with_lock(Engine.Mix.StackMutation, fn ->
          Mix.ProjectStack.post_config(prune_code_paths: false, build_path: build_path)
          Mix.Project.push(project.project_module, file, app)
        end)

        try do
          fun.(project.project_module)
        rescue
          ex ->
            blamed = Exception.blame(:error, ex, __STACKTRACE__)
            {:error, {:exception, blamed, __STACKTRACE__}}
        else
          result ->
            case result do
              error when is_tuple(error) and elem(error, 0) == :error ->
                error

              ok when is_tuple(ok) and elem(ok, 0) == :ok ->
                ok

              other ->
                {:ok, other}
            end
        after
          Engine.with_lock(Engine.Mix.StackMutation, fn -> Mix.Project.pop() end)
        end
      after
        File.cd!(old_cwd)
      end
    end)
  end

  defp with_lock(fun) do
    Engine.with_lock(__MODULE__, fun)
  end
end
