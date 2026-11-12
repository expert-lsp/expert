defmodule Expert.CodeIntelligence.Completion.Typespecs do
  @moduledoc """
  Provides type completion candidates inside typespecs.

  Candidates include built-in types, local types, and public remote types.
  """

  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.Context
  alias Expert.CodeIntelligence.Completion.Definitions
  alias Expert.CodeIntelligence.Completion.Matcher
  alias Expert.CodeIntelligence.Completion.Modules

  @built_in [
    {"any", [], "The top type, the set of all terms."},
    {"none", [], "The bottom type, which contains no terms."},
    {"dynamic", [], "A type that is compatible with every type."},
    {"atom", [], "Any atom."},
    {"map", [], "Any map."},
    {"pid", [], "A process identifier."},
    {"port", [], "A port identifier."},
    {"reference", [], "A unique reference, such as one from `make_ref/0`."},
    {"tuple", [], "A tuple of any size."},
    {"float", [], "A floating-point number."},
    {"integer", [], "An integer."},
    {"neg_integer", [], "A negative integer."},
    {"non_neg_integer", [], "A non-negative integer."},
    {"pos_integer", [], "A positive integer."},
    {"list", ["t"], "A proper list of `t`."},
    {"nonempty_list", ["t"], "A non-empty proper list of `t`."},
    {"maybe_improper_list", ["type1", "type2"], "A proper or improper list."},
    {"nonempty_improper_list", ["type1", "type2"], "A non-empty improper list."},
    {"nonempty_maybe_improper_list", ["type1", "type2"], "A non-empty proper or improper list."},
    {"term", [], "Same as `any()`."},
    {"arity", [], "The arity of a function, `0..255`."},
    {"as_boolean", ["t"], "A `t` used as a truthy or falsy value."},
    {"binary", [], "A binary."},
    {"nonempty_binary", [], "A binary with at least one byte."},
    {"bitstring", [], "A bitstring."},
    {"nonempty_bitstring", [], "A bitstring with at least one bit."},
    {"boolean", [], "`true` or `false`."},
    {"byte", [], "An integer in `0..255`."},
    {"char", [], "A Unicode code point, `0..0x10FFFF`."},
    {"charlist", [], "A list of characters."},
    {"nonempty_charlist", [], "A non-empty list of characters."},
    {"fun", [], "Any function."},
    {"function", [], "Any function."},
    {"identifier", [], "A pid, a port or a reference."},
    {"iodata", [], "An iolist or a binary."},
    {"iolist", [], "A list of bytes, binaries and iolists."},
    {"keyword", [], "A keyword list."},
    {"keyword", ["t"], "A keyword list with values of type `t`."},
    {"list", [], "A proper list of any terms."},
    {"nonempty_list", [], "A non-empty proper list of any terms."},
    {"maybe_improper_list", [], "A proper or improper list of any terms."},
    {"nonempty_maybe_improper_list", [], "A non-empty proper or improper list of any terms."},
    {"mfa", [], "A `{module, function, arity}` tuple."},
    {"module", [], "A module name."},
    {"no_return", [], "The return type of a function that never returns."},
    {"node", [], "A node name."},
    {"number", [], "An integer or a float."},
    {"struct", [], "Any struct."},
    {"timeout", [], "A non-negative integer or `:infinity`."}
  ]

  @spec matching(Context.t(), String.t()) :: [struct()]
  def matching(%Context{} = context, typed) do
    case String.split(typed, ".") do
      [hint] ->
        current = if context.module, do: types(context, context.module, hint, true), else: []
        current ++ built_in(hint)

      segments ->
        {parent, [hint]} = Enum.split(segments, -1)

        case parent do
          [":" <> _erlang = module] ->
            types(context, module, hint, false)

          _ ->
            module = Context.expand_alias(context, Enum.map(parent, &String.to_atom/1))
            types(context, module, hint, module == context.module)
        end
    end
  end

  defp built_in(hint) do
    for {name, arguments, doc} <- @built_in,
        Matcher.match?(name, hint) do
      candidate(name, arguments, nil, "", doc)
    end
    |> Enum.sort_by(&{&1.name, &1.arity})
  end

  defp types(context, module, hint, private?) do
    origin = if is_atom(module), do: inspect(module), else: module

    defined =
      case Map.fetch(context.definitions, module) do
        {:ok, %Definitions{} = definitions} ->
          for type <- definitions.types,
              private? or type.kind != :typep,
              name = Atom.to_string(type.name),
              Matcher.match?(name, hint),
              do: candidate(name, type.arguments, origin, type.spec, type.summary)

        :error ->
          []
      end

    compiled =
      case Modules.read(context.project, module) do
        {:ok, details} ->
          for %{name: name} = type <- details.types,
              Matcher.match?(name, hint),
              do: candidate(name, type.arguments, origin, type.spec, type.summary)

        :error ->
          []
      end

    (defined ++ compiled)
    |> Enum.uniq_by(&{&1.name, &1.arity})
    |> Enum.sort_by(&{&1.name, &1.arity})
  end

  defp candidate(name, arguments, origin, spec, doc) do
    %Candidate.Typespec{
      argument_names: arguments,
      arity: length(arguments),
      doc: doc,
      metadata: %{},
      name: name,
      origin: origin,
      signature: "#{name}(#{Enum.join(arguments, ", ")})",
      spec: spec,
      type: :type_spec
    }
  end
end
