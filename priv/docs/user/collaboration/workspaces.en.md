---
title: Workspaces
description: Shared team environments for collaborating with your colleagues
order: 3
---

# Workspaces

> **Enterprise feature.** Workspaces are available exclusively on enterprise plans. Contact [support@magus.digital](mailto:support@magus.digital) for more information.

A workspace is a shared environment for a team. It gives everyone a common home for conversations, making it easy to collaborate, share context, and keep work organized in one place.

## Creating a workspace

1. Click your account name or avatar in the sidebar to open the account menu.
2. Select **New workspace**.
3. Enter a workspace **name** (for example, "Design Team" or "Engineering").
4. Choose a **URL slug**: this is the short identifier used in the workspace's URL (for example, `design-team`). Slugs can only contain lowercase letters, numbers, and hyphens.
5. Click **Create workspace**.

You are the Owner of the new workspace.

## Inviting team members

1. Go to the workspace's **Settings** page.
2. Select the **Members** tab.
3. Enter the email address of the person you want to invite.
4. Choose their role (see below).
5. Click **Invite**.

Invited members receive an email. If they already have a Magus account, they can accept the invitation to join immediately. New users are prompted to create an account first.

## Member roles

| Role | Can chat | Create conversations | Manage members | Workspace settings |
|------|----------|----------------------|----------------|--------------------|
| Owner | Yes | Yes | Yes | Yes |
| Editor | Yes | Yes | No | No |
| Member | Yes | No | No | No |
| Observer | Read-only | No | No | No |

**Owner** has full control over the workspace, including billing, settings, and member management. There can be multiple owners.

**Editor** can create new conversations and participate in all team conversations.

**Member** can participate in team conversations but cannot create new ones.

**Observer** can read team conversations but cannot send messages.

## Team conversations vs personal conversations

Within a workspace, there are two kinds of conversations:

**Team conversations** are visible to all workspace members (according to their roles). They appear in the shared sidebar view. Use these for discussions the whole team should be able to see.

**Personal conversations** are private to you. They are not visible to other workspace members. Use these for individual work you want to keep separate from shared team activity.

When creating a new conversation, you can choose whether it belongs to the workspace (team) or to yourself (personal).

## Workspace settings

Access workspace settings by going to **Settings** from the workspace menu. From there you can:

- **Rename** the workspace or change the URL slug.
- **Manage members**: invite new members, change roles, or remove members.
- **Transfer ownership** to another member.
- **Delete the workspace**: this permanently removes all team conversations and cannot be undone.

## Switching between workspaces

If you belong to multiple workspaces, you can switch between them using the workspace selector at the top of the sidebar. Each workspace shows its own set of team conversations and members.

## Memory isolation across workspaces

Each workspace is its own bucket for AI memory. The agent's user-scoped memories — your stated preferences, facts the AI has picked up about how you work, things you've asked it to remember — are partitioned per workspace and never leak between them.

Concretely, if you're in your Work workspace and tell the agent "remember I prefer concise responses", that preference applies in Work conversations but does not show up when you switch to a Personal workspace or another workspace you belong to. Each workspace builds up its own picture of you. Your personal-mode memories (when you're not inside any workspace) are a separate bucket too.

This applies to all three memory scopes:

- **Conversation memories** are inherently scoped to a single conversation, which itself belongs to one workspace.
- **Agent memories** belong to the workspace the custom agent lives in.
- **User memories** are partitioned by `(your user, the current workspace)`. Other members of the workspace cannot see them. They are private to you, scoped to that workspace.

When a workspace is deleted, every memory that lived inside it is deleted with it. Your other workspaces and your personal-mode memories are untouched.
