defmodule Engine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Forge.Identifier.start()

    children =
      if Engine.project_node?() do
        [
          Engine.ApplicationCache,
          Engine.CodeMod.Format.Cache,
          Engine.Api.Proxy,
          Engine.Commands.Reindex,
          Engine.Module.Loader,
          Engine.Compilation.TraceBuffer,
          Engine.Dispatch,
          Engine.ModuleMappings,
          Engine.Build,
          Engine.ModuleStore,
          Engine.Build.CaptureServer
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Engine.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
