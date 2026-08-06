---
title: Workspaces
description: Shared team environments for collaborating with your colleagues
order: 3
---

# Workspaces

> **Enterprise feature.** Workspaces are available exclusively on enterprise plans. Contact [support@magus.digital](mailto:support@magus.digital) for more information.

A workspace is a shared environment for a team. It gives everyone a common home for conversations, making it easy to collaborate, share context, and keep work organized in one place.

## Creating a workspace

1. Click the workspace switcher at the top of the sidebar.
2. Select **New workspace**.
3. Enter a workspace **name** (for example, "Design Team" or "Engineering").
4. Adjust the **URL slug** if you like: this is the short identifier used in the workspace's URL (for example, `design-team`). It is derived from the name automatically and can only contain lowercase letters, numbers, and hyphens.
5. Click **Create workspace**.

You are the admin of the new workspace.

## Inviting team members

1. Open the workspace switcher and choose **Workspace settings**.
2. Go to the **Members** section.
3. Enter the email address of the person you want to invite.
4. Click **Invite**.

Invited members receive an email. If they already have a Magus account, they can accept the invitation to join immediately. New users are prompted to create an account first.

## Member roles

There are two roles in a workspace:

**Admin** has full control over the workspace: settings, member management, and implicit owner access to every shared resource in the workspace. The admin can transfer ownership to another member.

**Member** has standard access: they can participate in shared conversations, create their own, and share resources with the team.

(Read-only participation exists at the conversation level: see the Observer role in [Multiplayer](./multiplayer.en.md).)

## Team conversations vs personal conversations

Within a workspace, there are two kinds of conversations:

**Shared conversations** are visible to all workspace members. They appear in the **Shared** section of the sidebar. Use these for discussions the whole team should be able to see.

**Personal conversations** are private to you. They are not visible to other workspace members. Use these for individual work you want to keep separate from shared team activity.

New conversations start personal. To share one with the team, hover over it in the sidebar and click the share toggle (**Share with team**); the same toggle makes it private again.

## Workspace settings

Open the workspace switcher and choose **Workspace settings**. From there you can:

- **Rename** the workspace and toggle whether it is active.
- **Set a default agent** for the workspace.
- **Manage members**: invite new members, resend invitations, or remove members.
- **Transfer ownership** to another member.
- **Delete the workspace**: this permanently removes the workspace and all its conversations, files, prompts, and agents. You confirm by typing the workspace name. This cannot be undone.

The URL slug is fixed when the workspace is created.

## Switching between workspaces

If you belong to multiple workspaces, you can switch between them (and your personal space) using the workspace switcher at the top of the sidebar. Each workspace shows its own set of conversations and members.

## Memory isolation across workspaces

Each workspace is its own bucket for AI memory. The agent's user-scoped memories — your stated preferences, facts the AI has picked up about how you work, things you've asked it to remember — are partitioned per workspace and never leak between them.

Concretely, if you're in your Work workspace and tell the agent "remember I prefer concise responses", that preference applies in Work conversations but does not show up when you switch to a Personal workspace or another workspace you belong to. Each workspace builds up its own picture of you. Your personal-mode memories (when you're not inside any workspace) are a separate bucket too.

This applies to all three memory scopes:

- **Conversation memories** are inherently scoped to a single conversation, which itself belongs to one workspace.
- **Agent memories** belong to the workspace the custom agent lives in.
- **User memories** are partitioned by `(your user, the current workspace)`. Other members of the workspace cannot see them. They are private to you, scoped to that workspace.

When a workspace is deleted, every memory that lived inside it is deleted with it. Your other workspaces and your personal-mode memories are untouched.
