defmodule Magus.Agents.Skills.Registry do
  @moduledoc """
  Registry for built-in skills loaded from markdown files.

  Skills are loaded at application startup from /priv/skills/.
  The registry provides a compact index for system prompts and
  full content retrieval for the load_skill tool.

  ## Usage

      # Get formatted skills section for system prompt (returns "" if no skills)
      Magus.Agents.Skills.Registry.get_skills_section()

      # Get full skill content
      Magus.Agents.Skills.Registry.get_skill("poetry_writing")

      # List all skills (metadata only)
      Magus.Agents.Skills.Registry.list_skills()

      # Reload skills from disk (development)
      Magus.Agents.Skills.Registry.reload()
  """

  use GenServer
  require Logger

  @enforce_keys [:name, :content, :path]
  defstruct [:name, :description, :enabled, :tags, :tools, :content, :path]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          enabled: boolean(),
          tags: [String.t()],
          tools: [String.t()],
          content: String.t(),
          path: String.t()
        }

  # Client API

  @doc """
  Start the skills registry.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  List all skills with their metadata (no content).
  """
  @spec list_skills() :: [t()]
  def list_skills do
    GenServer.call(__MODULE__, :list_skills)
  end

  @doc """
  Get a skill by name, including full content.
  """
  @spec get_skill(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_skill(name) do
    GenServer.call(__MODULE__, {:get_skill, name})
  end

  @doc """
  Check if there are any skills registered.
  """
  @spec has_skills?() :: boolean()
  def has_skills? do
    GenServer.call(__MODULE__, :has_skills?)
  end

  @doc """
  Get a compact text index of skills for inclusion in system prompts.
  Returns a formatted list of skill names and descriptions.
  """
  @spec skill_index_text() :: String.t()
  def skill_index_text do
    GenServer.call(__MODULE__, :skill_index_text)
  end

  @doc """
  Get the formatted skills section for system prompts.
  Returns the complete section with header, or empty string if no skills.
  This is more efficient than calling has_skills? and skill_index_text separately.

  When `loaded_tools` is provided (list of tool name strings from conversation.skill_tools),
  skills whose tools are all present are annotated as "(loaded)".
  """
  @spec get_skills_section(list(String.t()) | nil) :: String.t()
  def get_skills_section(loaded_tools \\ nil) do
    GenServer.call(__MODULE__, {:get_skills_section, loaded_tools})
  end

  @doc """
  Reload skills from disk. Useful for development.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = build_state()
    {:ok, state}
  end

  @impl true
  def handle_call(:list_skills, _from, state) do
    # Return skills without content to reduce memory in response
    skills_metadata =
      Enum.map(state.skills, fn {_name, skill} ->
        %{skill | content: nil}
      end)

    {:reply, skills_metadata, state}
  end

  @impl true
  def handle_call({:get_skill, name}, _from, state) do
    case Map.get(state.skills, name) do
      nil -> {:reply, {:error, :not_found}, state}
      skill -> {:reply, {:ok, skill}, state}
    end
  end

  @impl true
  def handle_call(:has_skills?, _from, state) do
    {:reply, map_size(state.skills) > 0, state}
  end

  @impl true
  def handle_call(:skill_index_text, _from, state) do
    {:reply, state.index_text, state}
  end

  @impl true
  def handle_call({:get_skills_section, nil}, _from, state) do
    {:reply, state.skills_section, state}
  end

  @impl true
  def handle_call({:get_skills_section, loaded_tools}, _from, state) when is_list(loaded_tools) do
    section = build_skills_section_with_loaded(state.skills, loaded_tools)
    {:reply, section, state}
  end

  @impl true
  def handle_call(:reload, _from, _state) do
    state = build_state()
    Logger.info("Skills registry reloaded: #{map_size(state.skills)} skills loaded")
    {:reply, :ok, state}
  end

  # Private Functions

  defp build_state do
    skills = load_skills_from_disk()
    index_text = build_index_text(skills)
    skills_section = build_skills_section(skills, index_text)
    %{skills: skills, index_text: index_text, skills_section: skills_section}
  end

  defp build_index_text(skills) do
    skills
    |> Enum.map(fn {_name, skill} ->
      tools_text =
        case skill.tools do
          tools when is_list(tools) and tools != [] ->
            " (tools: #{Enum.join(tools, ", ")})"

          _ ->
            ""
        end

      "- **#{skill.name}**: #{skill.description}#{tools_text}"
    end)
    |> Enum.sort()
    |> Enum.join("\n")
  end

  defp build_skills_section(skills, _index_text) when map_size(skills) == 0, do: ""

  defp build_skills_section(_skills, index_text) do
    """
    ## Available Skills

    Specialized tools are organized into skills. Use `load_skill` to activate capabilities:

    #{index_text}

    Load the relevant skill when a user request requires specialized tools. You can load multiple skills.
    """
  end

  # Builds the skills section with "(loaded)" annotations for skills whose tools
  # are already present in the conversation's skill_tools list.
  defp build_skills_section_with_loaded(skills, _loaded_tools) when map_size(skills) == 0, do: ""

  defp build_skills_section_with_loaded(skills, loaded_tools) do
    loaded_set = MapSet.new(loaded_tools)

    index_text =
      skills
      |> Enum.map(fn {_name, skill} ->
        skill_is_loaded? =
          case skill.tools do
            tools when is_list(tools) and tools != [] ->
              Enum.all?(tools, &(&1 in loaded_set))

            _ ->
              false
          end

        loaded_tag = if skill_is_loaded?, do: " *(loaded)*", else: ""

        tools_text =
          case skill.tools do
            tools when is_list(tools) and tools != [] ->
              " (tools: #{Enum.join(tools, ", ")})"

            _ ->
              ""
          end

        "- **#{skill.name}**: #{skill.description}#{tools_text}#{loaded_tag}"
      end)
      |> Enum.sort()
      |> Enum.join("\n")

    """
    ## Available Skills

    Specialized tools are organized into skills. Use `load_skill` to activate capabilities:

    #{index_text}

    Load the relevant skill when a user request requires specialized tools. You can load multiple skills.
    Skills marked *(loaded)* are already active — do not reload them.
    """
  end

  defp load_skills_from_disk do
    skills_dir = skills_directory()

    if File.dir?(skills_dir) do
      skills_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.reduce(%{}, fn path, acc ->
        case parse_skill_file(path) do
          {:ok, skill} ->
            Logger.debug("Loaded skill: #{skill.name}")
            Map.put(acc, skill.name, skill)

          {:error, reason} ->
            Logger.warning("Failed to parse skill file #{path}: #{inspect(reason)}")
            acc
        end
      end)
    else
      Logger.debug("Skills directory not found: #{skills_dir}")
      %{}
    end
  rescue
    error ->
      Logger.error("Failed to load skills from disk: #{inspect(error)}")
      %{}
  end

  defp skills_directory do
    Application.app_dir(:magus, "priv/skills")
  end

  defp parse_skill_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, frontmatter, body} <- YamlFrontMatter.parse(content),
         {:ok, validated} <- validate_frontmatter(frontmatter),
         {:ok, fm} <- is_enabled(validated) do
      skill = %__MODULE__{
        name: fm.name,
        description: fm.description,
        tags: fm.tags,
        tools: fm.tools,
        content: String.trim(body),
        path: path
      }

      {:ok, skill}
    end
  end

  defp validate_frontmatter(%{"name" => name} = fm) when is_binary(name) and name != "" do
    {:ok,
     %{
       name: name,
       enabled: if(fm["enabled"] == nil, do: true, else: fm["enabled"]),
       description: fm["description"] || "",
       tags: List.wrap(fm["tags"]),
       tools: List.wrap(fm["tools"])
     }}
  end

  defp validate_frontmatter(_), do: {:error, :invalid_frontmatter}

  defp is_enabled(%{:enabled => true} = fm) do
    {:ok, fm}
  end

  defp is_enabled(_) do
    {:error, "Skill is disabled"}
  end
end
