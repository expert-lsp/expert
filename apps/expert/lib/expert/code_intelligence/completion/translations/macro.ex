defmodule Expert.CodeIntelligence.Completion.Translations.Macro do
  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.SortScope
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Expert.CodeIntelligence.Completion.Translations
  alias Expert.CodeIntelligence.Completion.Translations.Callable
  alias Expert.CodeIntelligence.Completion.Translations.Struct
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Document
  alias Forge.Document.Position
  alias GenLSP.Enumerations.CompletionItemKind

  @snippet_macros ~w(def defp defmacro defmacrop defimpl defmodule defprotocol defguard defguardp defexception test use)
  @unhelpful_macros ~w(:: alias! in and or destructure)

  defimpl Translatable, for: Candidate.Macro do
    def translate(macro, builder, %Env{} = env) do
      Translations.Macro.translate(macro, builder, env)
    end
  end

  def translate(%Candidate.Macro{name: name}, _builder, _env)
      when name in ["__before_compile__", "__using__", "__after_compile__"] do
    :skip
  end

  def translate(%Candidate.Macro{name: "def", arity: 2} = macro, builder, env) do
    function_snippet("def", "define a function", macro, builder, env)
  end

  def translate(%Candidate.Macro{name: "defp", arity: 2} = macro, builder, env) do
    function_snippet("defp", "define a private function", macro, builder, env)
  end

  def translate(%Candidate.Macro{name: "defmodule"} = macro, builder, env) do
    label = "defmodule (define a module)"
    suggestion = suggest_module_name(env.document)

    snippet = """
    defmodule ${1:#{suggestion}} do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "defmacro", arity: 2} = macro, builder, env) do
    label = "#{macro.name} (define a macro)"

    snippet = """
    defmacro ${1:name}($2) do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "defmacrop", arity: 2} = macro, builder, env) do
    label = "#{macro.name} (define a private macro)"

    snippet = """
    defmacrop ${1:name}($2) do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "defprotocol"} = macro, builder, env) do
    label = "#{macro.name} (define a protocol)"

    snippet = """
    defprotocol ${1:protocol_name} do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "defimpl", arity: 3} = macro, builder, env) do
    label = "#{macro.name} (define a protocol implementation)"

    snippet = """
    defimpl ${1:protocol_name}, for: ${2:struct_name} do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "defoverridable"} = macro, builder, env) do
    label = "#{macro.name} (mark a function as overridable)"

    snippet = "defoverridable ${1:keyword_or_behaviour}"

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "defdelegate", arity: 2} = macro, builder, env) do
    label = "#{macro.name} (define a delegate function)"

    snippet = "defdelegate ${1:call}(${2:args}), to: ${3:module}"

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "defguard", arity: 1} = macro, builder, env) do
    label = "#{macro.name} (define a guard macro)"

    snippet = "defguard ${1:guard}(${2:args}) when $0"

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "defguardp", arity: 1} = macro, builder, env) do
    label = "#{macro.name} (define a private guard macro)"

    snippet = "defguardp ${1:guard}(${2:args}) when $0"

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "defexception", arity: 1} = macro, builder, env) do
    label = "#{macro.name} (define an exception)"

    snippet = "defexception [${1::message}]"

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "defstruct", arity: 1} = macro, builder, env) do
    label = "#{macro.name} (define a struct)"

    snippet = "defstruct [${1:fields}]"

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "alias", arity: 2} = macro, builder, env) do
    label = "#{macro.name} (alias a module's name)"

    snippet = "alias $0"

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "use", arity: 2}, builder, env) do
    label = "use (invoke another module's __using__ macro)"
    snippet = "use $0"

    env
    |> builder.snippet(snippet,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: "use"
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "require" <> _, arity: 2} = macro, builder, env) do
    label = "#{macro.name} (require a module's macros)"

    snippet = "require $0"

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "quote" <> _, arity: 2} = macro, builder, env) do
    label = "#{macro.name} (quote block)"

    snippet = """
    quote $1 do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "receive" <> _, arity: 1} = macro, builder, env) do
    label = "#{macro.name} (receive block)"

    snippet = """
    receive do
      ${1:pattern} -> $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "try" <> _, arity: 1} = macro, builder, env) do
    label = "#{macro.name} (try / catch / rescue block)"

    snippet = """
    try do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "with" <> _, arity: 1} = macro, builder, env) do
    label = "#{macro.name} (with statement)"

    snippet = """
    with ${1:pattern} <- ${2:expression} do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "case", arity: 2} = macro, builder, env) do
    label = "#{macro.name} (case statement)"

    snippet = """
    case $1 do
      ${2:pattern} -> $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "if", arity: 2} = macro, builder, env) do
    label = "#{macro.name} (if statement)"

    snippet = """
    if $1 do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "import", arity: 2} = macro, builder, env) do
    label = "#{macro.name} (import a module's functions)"

    snippet = "import $0"

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "unless", arity: 2} = macro, builder, env) do
    label = "#{macro.name} (unless statement)"

    snippet = """
    unless $1 do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "cond"} = macro, builder, env) do
    label = "#{macro.name} (cond statement)"

    snippet = """
    cond do
      ${1:test} ->
        $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "for"} = macro, builder, env) do
    label = "#{macro.name} (comprehension)"

    snippet = """
    for ${1:pattern} <- ${2:enumerable} do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  @stub_label ~S(test "message"           )
  @plain_label ~S(test "message" do...     )
  @context_label ~S(test "message", %{} do...)

  def translate(%Candidate.Macro{name: "test", arity: 1}, builder, env) do
    stub_label = @stub_label

    stub_snippet = ~S(test "${0:message}")

    env
    |> builder.snippet(stub_snippet,
      detail: "A stub test",
      kind: CompletionItemKind.class(),
      label: stub_label,
      filter_text: "test"
    )
    |> builder.set_sort_scope(SortScope.remote(false, 2))
  end

  def translate(%Candidate.Macro{name: "test", arity: 2}, builder, env) do
    plain_label = @plain_label

    plain_snippet = """
    test "${1:message}" do
      $0
    end
    """

    env
    |> builder.snippet(plain_snippet,
      detail: "A test",
      kind: CompletionItemKind.class(),
      label: plain_label,
      filter_text: "test"
    )
    |> builder.set_sort_scope(SortScope.remote(false, 0))
  end

  def translate(%Candidate.Macro{name: "test", arity: 3}, builder, env) do
    context_label = @context_label

    context_snippet = """
    test "${1:message}", %{${2:context}} do
      $0
    end
    """

    env
    |> builder.snippet(context_snippet,
      detail: "A test that receives context",
      kind: CompletionItemKind.class(),
      label: context_label,
      filter_text: "test"
    )
    |> builder.set_sort_scope(SortScope.remote(false, 1))
  end

  def translate(%Candidate.Macro{name: "describe"}, builder, env) do
    snippet = """
    describe "${1:message}" do
      $0
    end
    """

    env
    |> builder.snippet(snippet,
      detail: "A describe block",
      kind: CompletionItemKind.class(),
      label: ~S(describe "message"),
      filter_text: "describe"
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: "__MODULE__"} = macro, builder, env) do
    if Env.in_context?(env, :struct_reference) do
      Struct.completion(env, builder, macro.name, macro.name)
    else
      env
      |> builder.plain_text("__MODULE__",
        detail: macro.spec,
        kind: CompletionItemKind.constant(),
        label: "__MODULE__",
        filter_text: "__MODULE__"
      )
      |> builder.set_sort_scope(SortScope.global())
    end
  end

  def translate(%Candidate.Macro{name: dunder_form} = macro, builder, env)
      when dunder_form in ~w(__CALLER__ __DIR__ __ENV__ __MODULE__ __STACKTRACE__) do
    env
    |> builder.plain_text(dunder_form,
      detail: macro.spec,
      kind: CompletionItemKind.constant(),
      label: dunder_form,
      filter_text: dunder_form
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  def translate(%Candidate.Macro{name: dunder_form}, _builder, _env)
      when dunder_form in ~w(__aliases__ __block__) do
    :skip
  end

  def translate(%Candidate.Macro{name: name}, _builder, _env)
      when name in @unhelpful_macros do
    :skip
  end

  def translate(%Candidate.Macro{name: name} = macro, _builder, env)
      when name not in @snippet_macros do
    Callable.completion(macro, env)
  end

  def translate(%Candidate.Macro{}, _builder, _env) do
    :skip
  end

  defp function_snippet(kind, label, %Candidate.Macro{} = macro, builder, env) do
    label = "#{macro.name} (#{label})"

    snippet =
      with {:ok, %Position{} = position} <- Env.prev_significant_position(env),
           {:ok, name, args} <- extract_spec_name_and_args(env, position) do
        args_snippet =
          case suggest_arg_names(args) do
            [] ->
              ""

            names ->
              placeholders =
                names
                |> Enum.with_index(1)
                |> Enum.map_join(", ", fn {name, i} -> "${#{i}:#{name}}" end)

              "(" <> placeholders <> ")"
          end

        """
        #{kind} #{name}#{args_snippet} do
          $0
        end
        """
      else
        _ ->
          """
          #{kind} ${1:name}($2) do
            $0
          end
          """
      end

    env
    |> builder.snippet(snippet,
      detail: macro.spec,
      kind: CompletionItemKind.class(),
      label: label,
      filter_text: macro.name
    )
    |> builder.set_sort_scope(SortScope.global())
  end

  defp extract_spec_name_and_args(%Env{} = env, %Position{} = position) do
    with {:ok, [maybe_spec | _]} <- Ast.path_at(env.analysis, position),
         {:@, _, [{:spec, _, [typespec]}]} <- maybe_spec,
         {:"::", _, [{name, _, args}, _return]} <- typespec do
      if is_list(args) do
        {:ok, name, args}
      else
        {:ok, name, []}
      end
    else
      _ -> :error
    end
  end

  defp suggest_arg_names(args) do
    Enum.with_index(args, fn
      {:"::", _, [{name, _, nil}, _]}, _i when is_atom(name) -> name
      _, i -> "arg_#{i + 1}"
    end)
  end

  defp suggest_module_name(%Document{} = document) do
    result =
      document.path
      |> Path.split()
      |> Enum.reduce(false, fn
        "lib", _ ->
          {:lib, []}

        "test", _ ->
          {:test, []}

        "support", {:test, _} ->
          {:lib, []}

        _, false ->
          false

        element, {type, elements} ->
          camelized = camelize_file_name(element)

          {type, [camelized | elements]}
      end)

    case result do
      {_, parts} ->
        parts
        |> Enum.reverse()
        |> Enum.join(".")

      false ->
        document.path
        |> Path.basename()
        |> camelize_file_name()
    end
  end

  defp camelize_file_name(file_name_with_extension) do
    file_name_with_extension
    |> Path.rootname()
    |> String.split(".")
    |> Enum.map_join(".", &Macro.camelize/1)
  end
end
