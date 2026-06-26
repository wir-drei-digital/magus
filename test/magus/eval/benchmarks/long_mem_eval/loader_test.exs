defmodule Magus.Eval.Benchmarks.LongMemEval.LoaderTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Benchmarks.LongMemEval.Loader

  test "load/1 reads a local file when :path is given" do
    path = Path.join([File.cwd!(), "test/support/fixtures/eval/longmemeval_sample.json"])
    assert {:ok, data} = Loader.load(path: path)
    assert is_list(data) and length(data) == 2
  end

  test "load/1 returns :no_dataset when no file is found" do
    assert {:error, :no_dataset} = Loader.load(path: "/nonexistent/longmemeval.json", url: nil)
  end
end
