defmodule Magus.Eval.Benchmarks.GAIA.LoaderTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Benchmarks.GAIA.Loader

  test "load/1 reads a local file when :path is given" do
    path = Path.join([File.cwd!(), "test/support/fixtures/eval/gaia_sample.json"])
    assert {:ok, data} = Loader.load(path: path)
    assert is_list(data) and length(data) == 3
  end

  test "load/1 returns :gaia_access when no local file and no token" do
    assert {:error, :gaia_access} = Loader.load(path: "/nonexistent/gaia.json", token: nil)
  end
end
