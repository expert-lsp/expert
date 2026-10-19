defmodule Expert.Namespace.Module do
  @namespace_prefix "XP"

  defdelegate prefixed?(module), to: Forge.Namespace.Module

  def apply(module_name) do
    cond do
      prefixed?(module_name) ->
        module_name

      module_name in Mix.Tasks.Namespace.app_names() ->
        :"xp_#{module_name}"

      true ->
        module_name
        |> Atom.to_string()
        |> apply_namespace()
    end
  end

  defp apply_namespace("Elixir." <> rest) do
    Mix.Tasks.Namespace.root_modules()
    |> Enum.map(fn module -> module |> Module.split() |> List.first() end)
    |> Enum.reduce_while(rest, fn root_module, module ->
      if has_root_module?(root_module, module) do
        namespaced_module =
          module
          |> String.replace(root_module, namespace(root_module), global: false)
          |> String.to_atom()

        {:halt, namespaced_module}
      else
        {:cont, module}
      end
    end)
    |> List.wrap()
    |> Module.concat()
  end

  defp apply_namespace(erlang_module) do
    String.to_atom(erlang_module)
  end

  defp has_root_module?(root_module, root_module), do: true

  defp has_root_module?(root_module, candidate) do
    String.contains?(candidate, append_trailing_period(root_module))
  end

  defp namespace(orig) do
    @namespace_prefix <> orig
  end

  defp append_trailing_period(str) do
    str <> "."
  end
end
