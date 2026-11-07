# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.IfElse.UseKeywordSyntaxTest do
  use Expert.Test.RefactorCase

  alias Expert.Refactor.IfElse.UseKeywordSyntax

  test "refactors if statement with keyword syntax" do
    assert_refactored(
      UseKeywordSyntax,
      """
      # v
      if true do
        bar
      end
      """,
      """
      if true, do: bar
      """
    )
  end

  test "refactors if else statement with keyword syntax" do
    assert_refactored(
      UseKeywordSyntax,
      """
      # v
      if true do
        bar
      else
        bar + 10
      end
      """,
      """
      if true,
        do: bar,
        else: bar + 10
      """
    )
  end

  test "ignores if statement with multiple inner statements" do
    assert_ignored(
      UseKeywordSyntax,
      """
      # v
      if true do
        bar + 10
        bar + 20
      end
      """
    )
  end

  test "ignores if else statement with multiple inner statements" do
    assert_ignored(
      UseKeywordSyntax,
      """
      # v
      if true do
        bar + 10
      else
        bar + 20
        bar + 40
      end
      """
    )
  end

  test "ignores if else statement already with keyword syntax" do
    assert_ignored(
      UseKeywordSyntax,
      """
      # v
      if true, do: bar
      """
    )
  end

  test "ignores the line below the if statement" do
    assert_ignored(
      UseKeywordSyntax,
      """
      if true,
      # v
        do: bar
      """
    )
  end
end
