defmodule Magus.Agents.Tools.Skills.CreateSkill do
  use Jido.Action,
    name: "create_skill",
    description: """
    Bundle work you built in the sandbox into a reusable skill. Provide a name,
    a one-line description, the SKILL.md body (instructions), and optionally the
    sandbox file paths to include. The skill becomes available to load later.
    """,
    schema: [
      name: [type: :string, required: true],
      description: [type: :string, required: true],
      body: [type: :string, required: true],
      include_paths: [type: {:or, [{:list, :string}, nil]}, default: nil],
      requested_tools: [type: {:or, [{:list, :string}, nil]}, default: nil],
      workspace_id: [type: {:or, [:string, nil]}, default: nil]
    ]

  import Magus.Agents.Tools.Helpers,
    only: [get_param: 2, get_context_value: 2, validate_context: 2]

  def display_name, do: "Creating skill..."
  def summarize_output(%{name: n}), do: "Created skill: #{n}"
  def summarize_output(%{error: _}), do: "Could not create skill"
  def summarize_output(_), do: "Done"

  @impl true
  def run(params, context) do
    with {:ok, ctx} <- validate_context(context, [:user_id, :conversation_id]) do
      user = get_context_value(context, :user)
      name = get_param(params, :name)
      include = get_param(params, :include_paths) || []

      with {:ok, files} <- read_sandbox_files(ctx.conversation_id, include, ctx.user_id),
           {:ok, zip} <- build_zip(name, params, files),
           {:ok, skill} <-
             Magus.Skills.Import.import_bundle(zip,
               actor: user,
               workspace_id: get_param(params, :workspace_id)
             ) do
        {:ok, %{skill_id: skill.id, name: skill.name}}
      else
        {:error, reason} -> {:ok, %{error: "Could not create skill: #{inspect(reason)}"}}
      end
    else
      {:error, msg} -> {:ok, %{error: msg}}
    end
  end

  defp read_sandbox_files(_conversation_id, [], _user_id), do: {:ok, []}

  defp read_sandbox_files(conversation_id, paths, user_id) do
    results =
      paths
      |> Enum.map(fn p ->
        case Magus.Sandbox.Orchestrator.read_file(conversation_id, p, user_id: user_id) do
          {:ok, %{content: c}} -> {relative(p), c}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, results}
  end

  # Bundle paths are stored relative to scripts/ so SKILL.md can reference them.
  defp relative(path), do: "scripts/" <> Path.basename(path)

  defp build_zip(name, params, files) do
    front = "---\nname: #{name}\ndescription: #{get_param(params, :description)}\n"

    allowed =
      case get_param(params, :requested_tools) do
        list when is_list(list) and list != [] -> "allowed-tools: #{Enum.join(list, " ")}\n"
        _ -> ""
      end

    skill_md = front <> allowed <> "---\n" <> (get_param(params, :body) || "")

    entries = [
      {~c"SKILL.md", skill_md}
      | Enum.map(files, fn {p, c} -> {String.to_charlist(p), c} end)
    ]

    case :zip.create(~c"skill.zip", entries, [:memory]) do
      {:ok, {_n, bytes}} -> {:ok, bytes}
      other -> other
    end
  end
end
