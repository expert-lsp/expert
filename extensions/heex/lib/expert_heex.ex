defmodule ExpertHEEx do
  @moduledoc "Provides code intelligence for HEEx templates."

  alias ExpertHEEx.Components
  alias ExpertHEEx.Scanner
  alias ExpertHEEx.Source

  Module.register_attribute(__MODULE__, :elixir_semantic_metadata,
    accumulate: true,
    persist: true
  )

  @language_ids ["phoenix-heex", "heex"]

  @elixir_semantic_metadata {
    :elixir_semantic_metadata_v1,
    %{
      contexts:
        Enum.map(@language_ids, &%{language_id: &1, scope: :heex}) ++
          [%{sigil: "H", scope: :heex}],
      scopes: %{
        heex: %{
          entries: [],
          data: [
            expert: %{
              facets: %{
                completion: [{__MODULE__, :complete, 1}],
                hover: [{__MODULE__, :hover, 1}],
                definition: [{__MODULE__, :definition, 1}],
                resolve: [{__MODULE__, :resolve, 1}]
              }
            }
          ]
        }
      }
    }
  }

  @code_tokens [:expr, :start_expr, :middle_expr, :end_expr]

  def complete(request), do: complete_template(request, template(request))

  def hover(request) do
    with {:ok, %{target: {_kind, name, start}} = at_cursor} <- html_at_cursor(request),
         reference when reference != nil <- reference(at_cursor),
         markdown when is_binary(markdown) <- Components.describe(request, reference) do
      {line, column} = start

      range = %{
        start: %{line: line, character: column},
        end: %{line: line, character: column + Source.columns(name)}
      }

      %{contents: markdown, range: range}
    else
      _ -> nil
    end
  end

  def definition(request) do
    with {:ok, at_cursor} <- html_at_cursor(request),
         reference when reference != nil <- reference(at_cursor) do
      Components.locate(request, reference)
    else
      _ -> []
    end
  end

  def resolve(%{position: position} = request) do
    template = template(request)

    with {:ok, spans, _at_cursor} <-
           code_spans(template.text, template.start, {position.line, position.character}),
         true <- in_code?(position, spans) do
      request |> masked(spans) |> delegate()
    else
      _ -> nil
    end
  end

  defp template(%{sigil: %{name: "H"} = sigil, source: source}),
    do: %{text: Source.slice(Source.lines(source), sigil.content), start: sigil.content.start}

  defp template(%{source: source}), do: %{text: source, start: %{line: 1, character: 1}}

  defp masked(%{sigil: %{name: "H"} = sigil, source: source}, spans),
    do: source |> Source.lines() |> Source.blank(sigil.range) |> Source.write_code(spans)

  defp masked(%{source: source}, spans) do
    source
    |> Source.lines()
    |> Map.new(fn {index, line} -> {index, Source.spaces(line)} end)
    |> Source.write_code(spans)
  end

  defp in_code?(position, spans),
    do:
      Enum.any?(spans, fn {start, code} ->
        within?(position, {start, Scanner.advance(start, code)})
      end)

  defp html_at_cursor(%{position: position} = request) do
    template = template(request)

    case code_spans(template.text, template.start, {position.line, position.character}) do
      {:ok, _spans, %{target: {_kind, _name, _start}} = at_cursor} -> {:ok, at_cursor}
      _result -> :error
    end
  end

  defp reference(%{target: {kind, name, _start}, open: open}) when kind in [:open, :close] do
    cond do
      String.starts_with?(name, ":") -> {:slot, enclosing_component(open), name}
      component_tag?(name) -> {:component, name}
      true -> nil
    end
  end

  defp reference(%{target: {:attribute, attribute, _start}, state: {:tag, tag}, open: open}) do
    cond do
      String.starts_with?(tag, ":") ->
        {:slot_attribute, enclosing_component(open), tag, attribute}

      component_tag?(tag) ->
        {:attribute, tag, attribute}

      true ->
        nil
    end
  end

  defp reference(_at_cursor), do: nil

  defp enclosing_component(open), do: Enum.find(open, &component_tag?/1)

  defp complete_template(%{position: position} = request, template) do
    case code_spans(template.text, template.start, {position.line, position.character}) do
      {:ok, spans, at_cursor} ->
        line_prefix =
          request.source
          |> String.split("\n")
          |> Enum.at(position.line - 1, "")
          |> Source.take(position.character - 1)

        case {in_code?(position, spans), Regex.run(~r/@(\w*)$/, line_prefix)} do
          {false, _assign} ->
            complete_html(request, at_cursor, line_prefix, spans)

          {true, [_match, hint]} ->
            request |> Components.assigns() |> replacing(request, hint) |> override()

          {true, nil} ->
            request |> masked(spans) |> delegate()
        end

      :error ->
        override([])
    end
  end

  defp complete_html(
         %{position: %{line: line, character: character}} = request,
         %{state: {:tag, name}, open: [name | open], attributes: attributes, target: target},
         line_prefix,
         spans
       ) do
    component = enclosing_component(open)

    case target do
      {:open, ^name, {^line, column}} ->
        complete_tag_name(request, Source.take(name, character - column), component, spans)

      {:attribute, attribute, {^line, column}} ->
        request
        |> attributes(name, component, List.delete(attributes, attribute))
        |> replacing(request, Source.take(attribute, character - column))
        |> override()

      nil ->
        if String.ends_with?(line_prefix, [" ", "\t"]) do
          request
          |> attributes(name, component, attributes)
          |> replacing(request, "")
          |> override()
        else
          override([])
        end

      _target ->
        override([])
    end
  end

  defp complete_html(_request, _at_cursor, _line_prefix, _spans), do: override([])

  defp component_tag?("." <> _name), do: true
  defp component_tag?(name), do: capitalized?(name)

  defp capitalized?(<<char, _rest::binary>>) when char in ?A..?Z, do: true
  defp capitalized?(_name), do: false

  defp attributes(request, ":" <> slot, component, present),
    do: Components.slot_attributes(request, component, slot, present)

  defp attributes(request, name, _component, present) do
    if component_tag?(name), do: Components.attributes(request, name, present), else: []
  end

  defp complete_tag_name(request, ":" <> hint, component, _spans) do
    request |> Components.slots(component) |> replacing(request, hint) |> override()
  end

  defp complete_tag_name(request, "." <> hint, _component, _spans),
    do: request |> Components.local() |> replacing(request, hint) |> override()

  defp complete_tag_name(request, name, _component, spans) do
    {modules, [last]} = name |> String.split(".") |> Enum.split(-1)

    cond do
      # `<Lay` or `<MyAppWeb.Lay`: a module name, which Elixir completion handles.
      capitalized?(last) ->
        %{line: line, character: character} = request.position

        {masked, _end} =
          Source.write(masked(request, spans), {line, character - Source.columns(name)}, name)

        delegate(masked)

      # `<Layouts.` or `<Layouts.ap`: the components of a module.
      modules != [] and Enum.all?(modules, &capitalized?/1) ->
        request
        |> Components.remote(Enum.join(modules, "."))
        |> replacing(request, last)
        |> override()

      # `<div`: an HTML element.
      true ->
        override([])
    end
  end

  defp delegate(lines),
    do: %{delegate: %{source: lines |> Enum.sort() |> Enum.map_join("\n", &elem(&1, 1))}}

  defp override(items), do: %{mode: :override, items: items, incomplete?: false}

  defp replacing(items, %{position: %{line: line, character: character}}, hint) do
    range = %{
      start: %{line: line, character: character - Source.columns(hint)},
      end: %{line: line, character: character}
    }

    Enum.map(items, &Map.put(&1, :range, range))
  end

  # Returns the Elixir code in the template as `{{line, column}, code}` pairs,
  # one for each `<% %>` tag and each `{}` interpolation. When the cursor is in
  # the HTML, it also returns:
  #
  #   * the scanner state, described in `scan/4`
  #   * the open tags
  #   * the attributes of the tag at the cursor
  #   * `target`, the tag or attribute name under the cursor, if any
  defp code_spans(template, %{line: line, character: column}, cursor) do
    with {:ok, tokens} <- Scanner.tokenize(template, line: line, column: column) do
      {_state, {events, _cursor}} =
        Enum.reduce(tokens, {:body, {[], cursor}}, fn
          {type, marker, code, %{line: line, column: column}}, {state, events}
          when type in @code_tokens ->
            start = {line, column + 2 + length(marker)}
            {state, push(events, {:code, start, List.to_string(code)})}

          {:text, text, %{line: line, column: column}}, {state, events} ->
            Scanner.scan(List.to_string(text), {line, column}, state, events)

          {:eof, _meta}, acc ->
            acc
        end)

      spans =
        Enum.reduce(events, [], fn
          {:code, start, code}, spans -> [{start, code} | spans]
          _event, spans -> spans
        end)

      {:ok, spans, at_cursor(events, cursor)}
    end
  end

  defp push({events, cursor}, event), do: {[event | events], cursor}

  # `events` are in reverse order, so the events before the cursor come after
  # it, latest first.
  defp at_cursor(events, cursor) do
    case Enum.split_while(events, &(not match?({:cursor, _state}, &1))) do
      {_after, [{:cursor, state} | before]} ->
        tag_events = Enum.take_while(before, &(not match?({:open, _name, _start}, &1)))

        %{
          state: state,
          open: before |> Enum.reverse() |> open_tags(),
          attributes: for({:attribute, name, _start} <- tag_events, do: name),
          target: target(List.first(before), cursor)
        }

      {_events, []} ->
        nil
    end
  end

  # The scanner reads a name that spans the cursor as a whole, so the name under
  # the cursor is the last event before the cursor.
  defp target({kind, name, {line, column}} = event, {line, cursor_column})
       when kind in [:open, :close, :attribute] do
    if cursor_column <= column + Source.columns(name), do: event
  end

  defp target(_event, _cursor), do: nil

  defp open_tags(events) do
    Enum.reduce(events, [], fn
      {:open, name, _start}, open ->
        [name | open]

      {:close, name, _start}, open ->
        case Enum.split_while(open, &(&1 != name)) do
          {inner, [^name | outer]} -> inner ++ outer
          {_inner, []} -> open
        end

      _event, open ->
        open
    end)
  end

  defp within?(%{line: line, character: character}, {start, stop}),
    do: {line, character} >= start and {line, character} <= stop
end
