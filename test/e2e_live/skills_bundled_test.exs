defmodule Magus.LiveE2E.SkillsBundledTest do
  @moduledoc """
  End-to-end tests for the bundled-skill runtime: import, approve, materialize,
  and the create_skill authoring loop.

  Probes sandbox availability in setup; tests skip gracefully when not configured.
  Sandbox resources are cleaned up in on_exit.
  """
  use Magus.LiveE2ECase, async: false

  alias Magus.Agents.Tools.Sandbox.{FileWrite, RunCode}
  alias Magus.Agents.Tools.Skills.{CreateSkill, LoadSkill}

  @moduletag :sandbox
  @moduletag timeout: 240_000

  setup %{user: user, model: model} do
    conversation = create_conversation(user, model)
    context = %{conversation_id: conversation.id, user_id: user.id, user: user}

    # Probe sandbox availability with a trivial code execution
    {:ok, probe} = RunCode.run(%{"code" => "print('probe')"}, context)
    sandbox? = probe[:success] == true

    unless sandbox? do
      IO.puts("\n    [sandbox not configured — sandbox tests will be skipped]")
    end

    on_exit(fn ->
      case Magus.Sandbox.get_sandbox_by_conversation(conversation.id, authorize?: false) do
        {:ok, sandbox} -> Magus.Sandbox.terminate(sandbox, authorize?: false)
        _ -> :ok
      end
    end)

    %{conversation: conversation, context: context, sandbox?: sandbox?}
  end

  # ── Test 1: import -> load (pending) -> approve -> load (materialize) -> file present ──

  describe "bundled skill runtime" do
    test "import -> load(pending) -> approve -> load(materialize) -> file present",
         %{user: user, conversation: conversation, context: ctx, sandbox?: sandbox?} do
      if sandbox? do
        bytes =
          build_zip([
            {"SKILL.md", "---\nname: e2e-skill\ndescription: d\n---\n# E2E\nrun scripts/go.py"},
            {"scripts/go.py", "print('ok')"}
          ])

        {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)
        ref = "user:" <> skill.id

        # First load: sandbox not yet approved — should return pending
        {:ok, r1} = LoadSkill.run(%{skill_name: ref}, ctx)
        assert r1.status == "pending"
        assert r1.content =~ "E2E"

        # Record approval (simulates user clicking "Approve skill: <id>")
        {:ok, _} =
          Magus.Skills.record_conversation_approval(
            %{
              conversation_id: conversation.id,
              skill_id: skill.id,
              bundle_sha: skill.bundle_sha,
              approved_by_id: user.id,
              source: :approval_card
            },
            authorize?: false
          )

        # Second load: approved — should materialize into sandbox
        {:ok, r2} = LoadSkill.run(%{skill_name: ref}, ctx)
        assert r2.materialized == "/workspace/.skills/e2e-skill"

        # Confirm the script file is actually present in the sandbox
        assert {:ok, %{content: "print('ok')"}} =
                 Magus.Sandbox.Orchestrator.read_file(
                   conversation.id,
                   "/workspace/.skills/e2e-skill/scripts/go.py",
                   user_id: user.id
                 )
      end
    end

    # ── Test 2: create_skill bundles a sandbox file into a reusable skill ──

    test "create_skill bundles a sandbox file into a reusable skill",
         %{user: user, context: ctx, sandbox?: sandbox?} do
      if sandbox? do
        # Write a file into the sandbox workspace
        {:ok, _} =
          FileWrite.run(
            %{"path" => "/workspace/mytool.py", "content" => "print('tool')"},
            ctx
          )

        # Bundle it as a skill via create_skill
        {:ok, result} =
          CreateSkill.run(
            %{
              "name" => "my-tool",
              "description" => "a tool",
              "body" => "# My Tool",
              "include_paths" => ["/workspace/mytool.py"]
            },
            ctx
          )

        assert is_binary(result.skill_id)

        # Retrieve the created skill and verify bundle metadata
        {:ok, created} = Magus.Skills.get_skill(result.skill_id, actor: user)
        assert created.has_executable_bundle == true

        assert Enum.any?(created.file_manifest, fn f -> f["path"] == "scripts/mytool.py" end),
               "expected scripts/mytool.py in file_manifest, got: #{inspect(created.file_manifest)}"
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
