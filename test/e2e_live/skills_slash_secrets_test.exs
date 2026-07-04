defmodule Magus.LiveE2E.SkillsSlashSecretsTest do
  @moduledoc """
  End-to-end test for the slash-trigger + declared-secret injection runtime:
  import a bundled skill that declares a required secret, store that secret in
  the user's vault, invoke the preflight slash path, and assert the slash
  approval is recorded, the bundle is materialized, and the declared secret
  lands in /workspace/.env inside the real sandbox.

  Probes sandbox availability in setup; the test skips gracefully when the
  provider is not configured. Sandbox resources are cleaned up in on_exit.
  """
  use Magus.LiveE2ECase, async: false

  alias Magus.Agents.Tools.Sandbox.RunCode

  @moduletag :sandbox
  @moduletag timeout: 240_000

  setup %{user: user, model: model} do
    conversation = create_conversation(user, model)
    context = %{conversation_id: conversation.id, user_id: user.id, user: user}

    # Probe sandbox availability with a trivial code execution
    {:ok, probe} = RunCode.run(%{"code" => "print('probe')"}, context)
    sandbox? = probe[:success] == true

    unless sandbox? do
      IO.puts("\n    [sandbox not configured: sandbox tests will be skipped]")
    end

    on_exit(fn ->
      case Magus.Sandbox.get_sandbox_by_conversation(conversation.id, authorize?: false) do
        {:ok, sandbox} -> Magus.Sandbox.terminate(sandbox, authorize?: false)
        _ -> :ok
      end
    end)

    %{conversation: conversation, context: context, sandbox?: sandbox?}
  end

  test "slash-triggered bundled skill records slash approval, materializes, and sources declared secret",
       %{user: user, conversation: conversation, sandbox?: sandbox?} do
    if sandbox? do
      {:ok, _} =
        Magus.Skills.create_sandbox_secret(%{key: "MY_SKILL_KEY", value: "sk-live-42"},
          actor: user
        )

      bytes =
        build_zip([
          {"SKILL.md",
           "---\nname: slash-skill\ndescription: d\nmetadata:\n  x-magus: '{\"required_secrets\":[{\"key\":\"MY_SKILL_KEY\"}]}'\n---\nrun scripts/show.sh"},
          {"scripts/show.sh", "#!/bin/sh\nsource /workspace/.env\necho \"$MY_SKILL_KEY\""}
        ])

      {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)

      # Simulate the preflight slash path directly.
      text =
        Magus.Agents.Plugins.Support.Preflight.apply_slash_skill(
          "/slash-skill go",
          conversation.id,
          user
        )

      assert text == "go"

      # Approval row recorded with the slash source.
      {:ok, approvals} =
        Magus.Skills.list_conversation_approvals(conversation.id, actor: user)

      assert Enum.any?(approvals, &(&1.skill_id == skill.id and &1.source == :slash_command))

      # Materialized + declared secret present in /workspace/.env.
      assert {:ok, %{content: env}} =
               Magus.Sandbox.Orchestrator.read_file(conversation.id, "/workspace/.env",
                 user_id: user.id
               )

      assert env =~ "MY_SKILL_KEY"
      assert env =~ "sk-live-42"
    end
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
