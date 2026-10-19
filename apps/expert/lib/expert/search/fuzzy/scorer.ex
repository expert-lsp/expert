defmodule Expert.Search.Fuzzy.Scorer do
  @moduledoc """
  Scores a fuzzy match based on heuristics.
  """
  import Record

  defstruct match?: false,
            index: 0,
            matched_character_positions: []

  defrecord :subject, graphemes: nil, normalized: nil, period_positions: [-1]

  @typedoc "A match score. Higher numbers mean a more relevant match."
  @type score :: integer
  @type score_result :: {match? :: boolean(), score}
  @type subject :: term()
  @type pattern :: String.t()
  @type preprocessed :: record(:subject, graphemes: tuple(), normalized: String.t())

  @non_match_score -5000
  @tail_match_boost 55
  @consecutive_character_bonus 15
  @mismatched_character_penalty 5
  @initial_period_positions MapSet.new([-1])

  @spec preprocess(subject()) :: preprocessed()
  def preprocess(subject) when is_binary(subject) do
    graphemes = String.graphemes(subject)

    subject(
      graphemes: List.to_tuple(graphemes),
      normalized: normalize(subject),
      period_positions: period_positions(subject, graphemes)
    )
  end

  def preprocess(subject) do
    subject
    |> inspect()
    |> preprocess()
  end

  @spec score(subject(), pattern()) :: score_result()
  def score(subject, pattern) when is_binary(subject) do
    subject
    |> preprocess()
    |> score(pattern)
  end

  def score(subject(normalized: normalized) = subject, pattern) do
    normalized_pattern = normalize(pattern)

    case collect_scores(normalized, normalized_pattern) do
      [] ->
        {false, @non_match_score}

      elems ->
        max_score =
          elems
          |> Enum.map(&calculate_score(&1, subject, pattern))
          |> Enum.max()

        {true, max_score}
    end
  end

  defp collect_scores(normalized, normalized_pattern, starting_index \\ 0, acc \\ [])

  defp collect_scores(normalized_subject, normalized_pattern, starting_index, scores) do
    initial_score = %__MODULE__{index: starting_index}

    case do_score(normalized_subject, normalized_pattern, initial_score) do
      %__MODULE__{match?: true, matched_character_positions: [pos | _]} = score ->
        slice_start = pos + 1
        next_index = starting_index + slice_start
        subject_substring = String.slice(normalized_subject, slice_start..-1//1)
        scores = [score | scores]
        collect_scores(subject_substring, normalized_pattern, next_index, scores)

      _ ->
        scores
    end
  end

  defp do_score(_, <<>>, %__MODULE__{} = score) do
    %__MODULE__{
      score
      | match?: true,
        matched_character_positions: Enum.reverse(score.matched_character_positions)
    }
  end

  defp do_score(<<>>, _, %__MODULE__{} = score) do
    %__MODULE__{
      score
      | matched_character_positions: Enum.reverse(score.matched_character_positions)
    }
  end

  defp do_score(
         <<match::utf8, subject_rest::binary>>,
         <<match::utf8, pattern_rest::binary>>,
         %__MODULE__{} = score
       ) do
    score =
      score
      |> add_to_list(:matched_character_positions, score.index)
      |> increment(:index)

    do_score(subject_rest, pattern_rest, score)
  end

  defp do_score(<<_unmatched::utf8, subject_rest::binary>>, pattern, %__MODULE__{} = score) do
    do_score(subject_rest, pattern, increment(score, :index))
  end

  def consecutive_match_boost(matched_positions) do
    max_streak =
      matched_positions
      |> Enum.reduce([[]], fn
        current, [[last | streak] | rest] when last == current - 1 ->
          [[current, last | streak] | rest]

        current, acc ->
          [[current] | acc]
      end)
      |> Enum.max_by(&length/1)

    streak_length = length(max_streak)
    {streak_length, @consecutive_character_bonus * streak_length}
  end

  def mismatched_penalty(matched_positions) do
    {penalty, _} =
      Enum.reduce(matched_positions, {0, -1}, fn
        matched_position, {0, _} ->
          {0, matched_position}

        matched_position, {penalty, last_position} ->
          penalty = penalty + (matched_position - last_position - 1)
          {penalty, matched_position}
      end)

    penalty * @mismatched_character_penalty
  end

  defp increment(%__MODULE__{index: index} = score, :index),
    do: %__MODULE__{score | index: index + 1}

  defp add_to_list(%__MODULE__{} = score, field_name, value) do
    Map.update(score, field_name, [value], &[value | &1])
  end

  defp calculate_score(%__MODULE__{match?: false}, _, _), do: @non_match_score

  defp calculate_score(%__MODULE__{} = score, subject(graphemes: graphemes) = subject, pattern) do
    pattern_length = String.length(pattern)

    {consecutive_count, consecutive_bonus} =
      consecutive_match_boost(score.matched_character_positions)

    match_amount_boost = consecutive_count * pattern_length
    match_boost = tail_match_boost(score, subject, pattern_length)
    camel_case_boost = camel_case_boost(score.matched_character_positions, subject)
    mismatched_penalty = mismatched_penalty(score.matched_character_positions)
    incompleteness_penalty = tuple_size(graphemes) - length(score.matched_character_positions)

    consecutive_bonus + match_boost + camel_case_boost + match_amount_boost - mismatched_penalty -
      incompleteness_penalty
  end

  defp tail_match_boost(
         %__MODULE__{} = score,
         subject(graphemes: graphemes, period_positions: period_positions),
         pattern_length
       ) do
    [first_match_position | _] = score.matched_character_positions

    match_end = first_match_position + pattern_length
    subject_length = tuple_size(graphemes)

    if MapSet.member?(period_positions, first_match_position - 1) and match_end == subject_length do
      @tail_match_boost
    else
      0
    end
  end

  defp camel_case_boost(matched_positions, subject(graphemes: graphemes)) do
    Enum.count(matched_positions, fn position ->
      position == 0 or uppercase?(elem(graphemes, position))
    end) * 10
  end

  defp uppercase?(<<char::utf8, _::binary>>) do
    char in ?A..?Z
  end

  defp uppercase?(_), do: false

  defp period_positions(subject, graphemes) do
    if :binary.match(subject, ".") == :nomatch do
      @initial_period_positions
    else
      find_period_positions(graphemes, 0, @initial_period_positions)
    end
  end

  defp find_period_positions([], _idx, acc), do: acc

  defp find_period_positions(["." | rest], idx, acc) do
    find_period_positions(rest, idx + 1, MapSet.put(acc, idx))
  end

  defp find_period_positions([_ | rest], idx, acc) do
    find_period_positions(rest, idx + 1, acc)
  end

  defp normalize(string), do: String.downcase(string)
end
