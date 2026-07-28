# Ports the Macro.Env expansion API introduced in Elixir 1.17.
# Source: https://github.com/elixir-lang/elixir/blob/v1.17.3/lib/elixir/lib/macro/env.ex
defmodule Future.Macro.Env do
  @moduledoc false

  if function_exported?(Macro.Env, :define_alias, 4) do
    defdelegate define_alias(env, meta, module, opts), to: Macro.Env
    defdelegate define_import(env, meta, module, opts), to: Macro.Env
    defdelegate define_require(env, meta, module, opts), to: Macro.Env
    defdelegate expand_alias(env, meta, aliases, opts), to: Macro.Env
    defdelegate expand_import(env, meta, name, arity, opts), to: Macro.Env
    defdelegate expand_require(env, meta, module, name, arity, opts), to: Macro.Env
  else
    def define_alias(env, meta, module, opts) do
      with {:ok, as} <- alias_as(module, opts) do
        {aliases, macro_aliases} = :elixir_aliases.store(meta, as, module, opts, env)
        {:ok, %{env | aliases: aliases, macro_aliases: macro_aliases}}
      end
    end

    def define_import(env, meta, module, opts) do
      {functions, macros} = :elixir_import.import(meta, module, Keyword.delete(opts, :trace), env)
      {:ok, %{require_module(env, module) | functions: functions, macros: macros}}
    rescue
      exception in CompileError -> {:error, Exception.message(exception)}
    end

    def define_require(env, meta, module, opts) do
      env = require_module(env, module)

      if Keyword.has_key?(opts, :as) do
        define_alias(env, meta, module, opts)
      else
        {:ok, env}
      end
    end

    def expand_alias(env, meta, aliases, _opts) do
      case :elixir_aliases.expand({:__aliases__, meta, aliases}, env) do
        alias when is_atom(alias) -> {:alias, alias}
        [_ | _] -> :error
      end
    end

    def expand_import(env, _meta, name, arity, _opts) do
      case Macro.Env.lookup_import(env, {name, arity}) do
        [{:function, module}] -> {:function, module, name}
        [{:macro, module}] -> {:macro, module, expand_once(env, {name, [], []})}
        [] -> {:error, :not_found}
        imports -> {:error, {:ambiguous, Enum.map(imports, &elem(&1, 1))}}
      end
    end

    def expand_require(env, _meta, module, name, arity, _opts) do
      if (module == env.module or module in env.requires) and Code.ensure_loaded?(module) and
           {name, arity} in module.__info__(:macros) do
        {:macro, module, expand_once(env, {{:., [], [module, name]}, [], []})}
      else
        :error
      end
    end

    defp alias_as(module, opts) do
      case Keyword.fetch(opts, :as) do
        {:ok, as} when is_atom(as) and as not in [true, false] -> {:ok, as}
        {:ok, as} -> {:error, "invalid alias: #{Macro.to_string(as)}"}
        :error -> infer_alias(module)
      end
    end

    defp infer_alias(module) do
      case :elixir_aliases.last(module) do
        {:ok, as} -> {:ok, as}
        :error -> {:error, "alias cannot be inferred for #{inspect(module)}"}
      end
    end

    defp require_module(env, module),
      do: %{env | requires: :ordsets.add_element(module, env.requires)}

    defp expand_once(env, template) do
      fn meta, args ->
        template
        |> put_elem(1, meta)
        |> put_elem(2, args)
        |> Macro.expand_once(env)
      end
    end
  end
end
