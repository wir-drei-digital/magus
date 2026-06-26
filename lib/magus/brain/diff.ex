defmodule Magus.Brain.Diff do
  @moduledoc """
  Pure line + word level diff between two markdown bodies, shaped for the
  brain version viewer. Returns a flat list of row maps the template maps
  directly to styled lines.

  Row shapes:

    * `%{kind: :context, tokens: [{:same, binary}]}`
    * `%{kind: :del, tokens: [{:same | :removed, binary}, ...]}`
    * `%{kind: :ins, tokens: [{:same | :added, binary}, ...]}`
    * `%{kind: :gap, count: pos_integer}`

  Built on `List.myers_difference/2`: once on lines, then on word tokens
  within paired removed/added lines so a one-word edit highlights only the
  changed word (GitHub-style intra-line diff).
  """

  @default_context 3

  @doc """
  Diff rows for `old_body` -> `new_body`. Returns `[]` for identical bodies.

  Options:
    * `:context` (default #{@default_context}) — unchanged lines kept on
      each side of a change; longer unchanged runs collapse to a `:gap`.
  """
  @spec line_word_diff(binary(), binary(), keyword()) :: [map()]
  def line_word_diff(old_body, new_body, opts \\ [])
      when is_binary(old_body) and is_binary(new_body) do
    if old_body == new_body do
      []
    else
      context = Keyword.get(opts, :context, @default_context)

      split_lines(old_body)
      |> List.myers_difference(split_lines(new_body))
      |> to_rows()
      |> collapse_context(context)
    end
  end

  defp split_lines(""), do: []
  defp split_lines(body), do: String.split(body, "\n")

  # Walk the line-level edit script, buffering del/ins runs and flushing on
  # each :eq boundary (and at the end) so a deletion immediately followed by
  # an insertion is paired into a word-level diff.
  defp to_rows(diff), do: do_to_rows(diff, [], [], [])

  defp do_to_rows([], dels, inss, acc) do
    acc |> flush(dels, inss) |> Enum.reverse()
  end

  defp do_to_rows([{:eq, lines} | rest], dels, inss, acc) do
    acc = flush(acc, dels, inss)
    acc = Enum.reduce(lines, acc, fn line, a -> [context_row(line) | a] end)
    do_to_rows(rest, [], [], acc)
  end

  defp do_to_rows([{:del, lines} | rest], dels, inss, acc) do
    do_to_rows(rest, [lines | dels], inss, acc)
  end

  defp do_to_rows([{:ins, lines} | rest], dels, inss, acc) do
    do_to_rows(rest, dels, [lines | inss], acc)
  end

  # `acc` is the reversed row list. Emits all del rows, then all ins rows,
  # so a replace reads as removed-block then added-block (standard unified
  # order) while paired lines still carry word-level highlights.
  defp flush(acc, [], []), do: acc

  defp flush(acc, dels, inss) do
    # Buffers arrive as reverse-ordered lists-of-lines-chunks; restore order.
    dels = dels |> Enum.reverse() |> List.flatten()
    inss = inss |> Enum.reverse() |> List.flatten()

    pair_count = min(length(dels), length(inss))
    {paired_dels, extra_dels} = Enum.split(dels, pair_count)
    {paired_inss, extra_inss} = Enum.split(inss, pair_count)

    {paired_del_rows, paired_ins_rows} =
      paired_dels
      |> Enum.zip(paired_inss)
      |> Enum.map(fn {d, i} ->
        {del_tokens, ins_tokens} = word_diff(d, i)
        {%{kind: :del, tokens: del_tokens}, %{kind: :ins, tokens: ins_tokens}}
      end)
      |> Enum.unzip()

    del_rows = paired_del_rows ++ Enum.map(extra_dels, &whole_del/1)
    ins_rows = paired_ins_rows ++ Enum.map(extra_inss, &whole_ins/1)

    acc = Enum.reduce(del_rows, acc, fn r, a -> [r | a] end)
    Enum.reduce(ins_rows, acc, fn r, a -> [r | a] end)
  end

  defp context_row(line), do: %{kind: :context, tokens: [{:same, line}]}
  defp whole_del(line), do: %{kind: :del, tokens: [{:removed, line}]}
  defp whole_ins(line), do: %{kind: :ins, tokens: [{:added, line}]}

  # Word-level diff between a single removed line and a single added line.
  defp word_diff(old_line, new_line) do
    diff = List.myers_difference(tokenize(old_line), tokenize(new_line))

    del_tokens =
      diff
      |> Enum.flat_map(fn
        {:eq, toks} -> [{:same, Enum.join(toks)}]
        {:del, toks} -> [{:removed, Enum.join(toks)}]
        {:ins, _toks} -> []
      end)
      |> merge_adjacent()

    ins_tokens =
      diff
      |> Enum.flat_map(fn
        {:eq, toks} -> [{:same, Enum.join(toks)}]
        {:del, _toks} -> []
        {:ins, toks} -> [{:added, Enum.join(toks)}]
      end)
      |> merge_adjacent()

    {del_tokens, ins_tokens}
  end

  # Split into a list of words and whitespace runs, preserving both so the
  # rejoined tokens reconstruct the original line exactly.
  defp tokenize(""), do: []

  defp tokenize(line) do
    ~r/\S+|\s+/
    |> Regex.scan(line)
    |> Enum.map(&hd/1)
  end

  defp merge_adjacent(tokens) do
    tokens
    # Myers never emits empty token lists; this reject is purely defensive.
    |> Enum.reject(fn {_kind, text} -> text == "" end)
    |> Enum.reduce([], fn
      {kind, text}, [{kind, prev} | rest] -> [{kind, prev <> text} | rest]
      token, acc -> [token | acc]
    end)
    |> Enum.reverse()
  end

  # Collapse maximal runs of :context rows longer than the context window.
  defp collapse_context(rows, context) do
    chunks =
      Enum.chunk_by(rows, fn %{kind: kind} -> kind == :context end)
      |> Enum.map(fn group ->
        if match?(%{kind: :context}, hd(group)), do: {:ctx, group}, else: {:change, group}
      end)

    count = length(chunks)

    chunks
    |> Enum.with_index()
    |> Enum.map(fn
      {{:change, group}, _i} -> group
      {{:ctx, group}, i} -> collapse_ctx(group, context, i > 0, i < count - 1)
    end)
    |> List.flatten()
  end

  defp collapse_ctx(group, context, has_prev, has_next) do
    len = length(group)
    head_n = if has_prev, do: context, else: 0
    tail_n = if has_next, do: context, else: 0

    if head_n + tail_n >= len do
      group
    else
      head = Enum.take(group, head_n)
      tail = Enum.take(group, -tail_n)
      [head, %{kind: :gap, count: len - head_n - tail_n}, tail]
    end
  end
end
