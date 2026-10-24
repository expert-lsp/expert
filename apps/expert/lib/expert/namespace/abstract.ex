defmodule Expert.Namespace.Abstract do
  @moduledoc """
  Transformations from erlang abstract syntax

  The abstract syntax is rather tersely defined here:
  https://www.erlang.org/doc/apps/erts/absform.html
  """

  alias Expert.Namespace.Module, as: NamespaceModule

  def rewrite(abstract_format) when is_list(abstract_format) do
    Enum.map(abstract_format, &rewrite/1)
  end

  def rewrite(abstract_format) do
    do_rewrite(abstract_format)
  end

  # 8.1  Module Declarations and Forms

  defp do_rewrite({:attribute, anno, :export, exported_functions}) do
    {:attribute, anno, :export, rewrite(exported_functions)}
  end

  defp do_rewrite({:attribute, anno, :behaviour, module}) do
    {:attribute, anno, :behaviour, rewrite_module(module)}
  end

  defp do_rewrite({:attribute, anno, :import, {module, funs}}) do
    {:attribute, anno, :import, {rewrite_module(module), rewrite(funs)}}
  end

  defp do_rewrite({:attribute, anno, :module, mod}) do
    {:attribute, anno, :module, rewrite_module(mod)}
  end

  defp do_rewrite({:attribute, anno, :__impl__, attrs}) do
    {:attribute, anno, :__impl__, rewrite(attrs)}
  end

  defp do_rewrite({:function, anno, name, arity, clauses}) do
    {:function, anno, name, arity, rewrite(clauses)}
  end

  defp do_rewrite({:attribute, anno, spec, {{name, arity}, spec_clauses}}) do
    {:attribute, anno, rewrite(spec), {{name, arity}, rewrite(spec_clauses)}}
  end

  defp do_rewrite({:attribute, anno, :spec, {{mod, name, arity}, clauses}}) do
    {:attribute, anno, :spec, {{rewrite(mod), name, arity}, rewrite(clauses)}}
  end

  defp do_rewrite({:attribute, anno, :record, {name, fields}}) do
    {:attribute, anno, :record, {rewrite_module(name), rewrite(fields)}}
  end

  defp do_rewrite({:attribute, anno, type, {name, type_rep, clauses}}) do
    {:attribute, anno, type, {name, rewrite(type_rep), rewrite(clauses)}}
  end

  defp do_rewrite({:for, target}) when is_atom(target) do
    # Protocol implementation
    {:for, rewrite_module(target)}
  end

  defp do_rewrite({:for, target}) do
    {:for, rewrite(target)}
  end

  defp do_rewrite({:protocol, protocol}) when is_atom(protocol) do
    {:protocol, rewrite_module(protocol)}
  end

  # Record Fields

  defp do_rewrite({:record_field, anno, repr}) do
    {:record_field, anno, rewrite(repr)}
  end

  defp do_rewrite({:record_field, anno, repr_1, repr_2}) do
    {:record_field, anno, rewrite(repr_1), rewrite(repr_2)}
  end

  defp do_rewrite({:typed_record_field, {:record_field, anno, repr_1}, repr_2}) do
    {:typed_record_field, {:record_field, anno, rewrite(repr_1)}, rewrite(repr_2)}
  end

  defp do_rewrite({:typed_record_field, {:record_field, anno, repr_a, repr_e}, repr_t}) do
    {:typed_record_field, {:record_field, anno, rewrite(repr_a), rewrite(repr_e)},
     rewrite(repr_t)}
  end

  # Representation of Parse Errors and End-of-File Omitted; not necessary
  # 8.2  Atomic Literals

  # only rewrite atoms, since they might be modules
  defp do_rewrite({:atom, anno, literal}) do
    {:atom, anno, rewrite_module(literal)}
  end

  # 8.3  Patterns
  # ignore bitstraings, they can't contain modules

  defp do_rewrite({:match, anno, lhs, rhs}) do
    {:match, anno, rewrite(lhs), rewrite(rhs)}
  end

  defp do_rewrite({:cons, anno, head, tail}) do
    {:cons, anno, rewrite(head), rewrite(tail)}
  end

  defp do_rewrite({:map, anno, matches}) do
    {:map, anno, rewrite(matches)}
  end

  defp do_rewrite({:op, anno, op, lhs, rhs}) do
    {:op, anno, op, rewrite(lhs), rewrite(rhs)}
  end

  defp do_rewrite({:op, anno, op, pattern}) do
    {:op, anno, op, rewrite(pattern)}
  end

  defp do_rewrite({:tuple, anno, patterns}) do
    {:tuple, anno, rewrite(patterns)}
  end

  defp do_rewrite({:var, anno, atom}) do
    {:var, anno, rewrite_module(atom)}
  end

  # 8.4  Expressions

  defp do_rewrite({:bc, anno, rep_e0, qualifiers}) do
    {:bc, anno, rewrite(rep_e0), rewrite(qualifiers)}
  end

  defp do_rewrite({:bin, anno, bin_elements}) do
    {:bin, anno, rewrite(bin_elements)}
  end

  defp do_rewrite({:bin_element, anno, elem, size, type}) do
    {:bin_element, anno, rewrite(elem), size, type}
  end

  defp do_rewrite({:block, anno, body}) do
    {:block, anno, rewrite(body)}
  end

  defp do_rewrite({:case, anno, expression, clauses}) do
    {:case, anno, rewrite(expression), rewrite(clauses)}
  end

  defp do_rewrite({:catch, anno, expression}) do
    {:catch, anno, rewrite(expression)}
  end

  defp do_rewrite({:fun, anno, {:function, name, arity}}) do
    {:fun, anno, {:function, rewrite(name), arity}}
  end

  defp do_rewrite({:fun, anno, {:function, module, name, arity}}) do
    {:fun, anno, {:function, rewrite(module), rewrite(name), arity}}
  end

  defp do_rewrite({:fun, anno, {:clauses, clauses}}) do
    {:fun, anno, {:clauses, rewrite(clauses)}}
  end

  defp do_rewrite({:named_fun, anno, name, clauses}) do
    {:named_fun, anno, rewrite(name), rewrite(clauses)}
  end

  defp do_rewrite({:call, anno, {:remote, remote_anno, module, fn_name}, args}) do
    {:call, anno, {:remote, remote_anno, rewrite(module), fn_name}, rewrite(args)}
  end

  defp do_rewrite({:call, anno, name, args}) do
    {:call, anno, rewrite(name), rewrite(args)}
  end

  defp do_rewrite({:if, anno, clauses}) do
    {:if, anno, rewrite(clauses)}
  end

  defp do_rewrite({:lc, anno, expression, qualifiers}) do
    {:lc, anno, rewrite(expression), rewrite(qualifiers)}
  end

  defp do_rewrite({:map, anno, expression, clauses}) do
    {:map, anno, rewrite(expression), rewrite(clauses)}
  end

  defp do_rewrite({:maybe_match, anno, lhs, rhs}) do
    {:maybe_match, anno, rewrite(lhs), rewrite(rhs)}
  end

  defp do_rewrite({:maybe, anno, body}) do
    {:maybe, anno, rewrite(body)}
  end

  defp do_rewrite({:maybe, anno, maybe_body, {:else, anno, else_clauses}}) do
    {:maybe, anno, rewrite(maybe_body), {:else, anno, rewrite(else_clauses)}}
  end

  defp do_rewrite({:receive, anno, clauses}) do
    {:receive, anno, rewrite(clauses)}
  end

  defp do_rewrite({:receive, anno, cases, expression, body}) do
    {:receive, anno, rewrite(cases), rewrite(expression), rewrite(body)}
  end

  defp do_rewrite({:record, anno, name, fields}) do
    {:record, anno, rewrite_module(name), rewrite(fields)}
  end

  defp do_rewrite({:record_field, anno, record_name, field_name, record_field}) do
    {:record_field, anno, rewrite_module(record_name), field_name, record_field}
  end

  defp do_rewrite({:try, anno, body, case_clauses, catch_clauses}) do
    {:try, anno, rewrite(body), rewrite(case_clauses), rewrite(catch_clauses)}
  end

  defp do_rewrite({:try, anno, body, case_clauses, catch_clauses, after_clauses}) do
    {:try, anno, rewrite(body), rewrite(case_clauses), rewrite(catch_clauses),
     rewrite(after_clauses)}
  end

  # Qualifiers

  defp do_rewrite({:generate, anno, lhs, rhs}) do
    {:generate, anno, rewrite(lhs), rewrite(rhs)}
  end

  defp do_rewrite({:b_generate, anno, lhs, rhs}) do
    {:b_generate, anno, rewrite(lhs), rewrite(rhs)}
  end

  # Associations

  defp do_rewrite({:map_field_assoc, anno, key, value}) do
    {:map_field_assoc, anno, rewrite(key), rewrite(value)}
  end

  defp do_rewrite({:map_field_exact, anno, key, value}) do
    {:map_field_exact, anno, rewrite(key), rewrite(value)}
  end

  # 8.5  Clauses

  defp do_rewrite({:clause, anno, lhs, guards, rhs}) do
    {:clause, anno, rewrite(lhs), rewrite(guards), rewrite(rhs)}
  end

  # 8.6  Guards
  # Guards seem covered by above clauses

  # 8.7  Types
  defp do_rewrite({:ann_type, anno, clauses}) do
    {:ann_type, anno, rewrite(clauses)}
  end

  defp do_rewrite({:type, anno, :fun, [{:type, type_anno, :any}, type]}) do
    {:type, anno, :fun, [{:type, type_anno, :any}, rewrite(type)]}
  end

  defp do_rewrite({:type, anno, :map, key_values}) do
    {:type, anno, :map, rewrite(key_values)}
  end

  defp do_rewrite({:type, anno, predefined_type, expressions}) do
    {:type, anno, rewrite(predefined_type), rewrite(expressions)}
  end

  defp do_rewrite({:remote_type, anno, [module, name, expressions]}) do
    {:remote_type, anno, [rewrite_module(module), name, rewrite(expressions)]}
  end

  defp do_rewrite({:user_type, anno, name, types}) do
    {:user_type, anno, rewrite_module(name), rewrite(types)}
  end

  # Catch all
  defp do_rewrite(other) do
    other
  end

  defp rewrite_module({:atom, sequence, literal}) do
    {:atom, sequence, rewrite_module(literal)}
  end

  defp rewrite_module({:var, anno, name}) do
    {:var, anno, rewrite_module(name)}
  end

  defp rewrite_module(module) do
    NamespaceModule.apply(module)
  end
end
