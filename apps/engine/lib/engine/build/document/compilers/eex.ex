defmodule Engine.Build.Document.Compilers.EEx do
  @moduledoc """
  A compiler for .eex files
  """
  @behaviour Engine.Build.Document.Compiler

  alias Engine.Build
  alias Engine.Build.Document.Compilers
  alias Forge.Diagnostic
  alias Forge.Document

  @impl true
  def recognizes?(%Document{language_id: "eex"}), do: true
  def recognizes?(_), do: false

  @impl true
  def enabled?, do: true

  @impl true
  def compile(%Document{} = document) do
    with {:ok, quoted} <- eex_to_quoted(document),
         :ok <- eval_quoted(document, quoted) do
      compile_quoted(document, quoted)
    end
  end

  defp compile_quoted(%Document{} = document, quoted) do
    with {:error, errors} <- Compilers.Quoted.compile(document, quoted, "EEx") do
      {:error, reject_undefined_assigns(errors)}
    end
  end

  defp eex_to_quoted(%Document{} = document) do
    quoted =
      document
      |> Document.to_string()
      |> EEx.compile_string(file: document.path)

    {:ok, quoted}
  rescue
    error ->
      {:error, [error_to_result(document, error)]}
  end

  @spec eval_quoted(Document.t(), Macro.t()) :: :ok | {:error, [Diagnostic.t()]}
  def eval_quoted(%Document{} = document, quoted_ast) do
    result =
      if Elixir.Features.with_diagnostics?() do
        eval_quoted_with_diagnostics(quoted_ast, document.path)
      else
        do_eval_quoted(quoted_ast, document.path)
      end

    case result do
      {:ok, _eval_result} ->
        :ok

      {{:ok, _eval_result}, _} ->
        # Ignore warnings for now
        # because they will be handled by `compile_quoted/2`
        # like: `assign @thing not available in EEx template`
        :ok

      {:exception, exception, stack, _quoted_ast} ->
        converted =
          document
          |> Build.Error.error_to_diagnostic(exception, stack, quoted_ast)
          |> Map.put(:source, "EEx")

        {:error, [converted]}

      {{:exception, exception, stack, _quoted_ast}, all_errors_and_warnings} ->
        converted = Build.Error.error_to_diagnostic(document, exception, stack, quoted_ast)
        maybe_diagnostics = Build.Error.diagnostics_from_mix(document, all_errors_and_warnings)

        diagnostics =
          [converted | maybe_diagnostics]
          |> Enum.reverse()
          |> Build.Error.refine_diagnostics()
          |> Enum.map(&Map.replace!(&1, :source, "EEx"))

        {:error, diagnostics}
    end
  end

  defp eval_quoted_with_diagnostics(quoted_ast, path) do
    # Using apply to prevent a compile warning on elixir < 1.15
    # credo:disable-for-next-line
    apply(Code, :with_diagnostics, [fn -> do_eval_quoted(quoted_ast, path) end])
  end

  def do_eval_quoted(quoted_ast, path) do
    eval_heex_quoted? =
      quoted_ast
      |> Macro.path(&match?({:require, [context: Phoenix.LiveView.TagEngine], _}, &1))
      |> then(&(not is_nil(&1)))

    env =
      if eval_heex_quoted? do
        # __ENV__ is required for heex quoted evaluations.
        Map.put(__ENV__, :file, path)
      else
        [file: path]
      end

    try do
      {result, _} = Code.eval_quoted(quoted_ast, [assigns: %{}], env)
      {:ok, result}
    rescue
      exception ->
        {filled_exception, stack} = Exception.blame(:error, exception, __STACKTRACE__)
        {:exception, filled_exception, stack, quoted_ast}
    end
  end

  defp reject_undefined_assigns(errors) do
    # NOTE: Ignoring error for assigns makes sense,
    # because we don't want such a error report,
    # for example: `<%= @name %>`
    Enum.reject(errors, fn %Diagnostic{message: message} ->
      message =~ ~s[undefined variable "assigns"]
    end)
  end

  defp error_to_result(%Document{} = document, %EEx.SyntaxError{} = error) do
    position = {error.line, error.column}

    Diagnostic.new(document.uri, position, error.message, :error, "EEx")
  end
end
