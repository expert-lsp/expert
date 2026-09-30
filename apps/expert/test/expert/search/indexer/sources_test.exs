defmodule Expert.Search.Indexer.SourcesTest do
  use ExUnit.Case, async: false

  alias Expert.Search.Indexer.Sources

  @tag :tmp_dir
  test "skips files that raise while indexing other sources", %{tmp_dir: tmp_dir} do
    broken_path = Path.join(tmp_dir, "broken.ex")
    indexed_path = Path.join(tmp_dir, "indexed.ex")
    entry = %{subtype: :definition}

    File.write!(broken_path, "defmodule Broken do end")
    File.write!(indexed_path, "defmodule Indexed do end")

    source_indexer = fn
      ^broken_path, _contents -> raise "boom"
      ^indexed_path, _contents -> {:ok, [entry]}
    end

    assert [{^entry, [_manifest_entry]}] =
             [broken_path, indexed_path]
             |> Sources.stream(source_indexer)
             |> Enum.to_list()
  end
end
