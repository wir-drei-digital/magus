defmodule Magus.Repo.Migrations.RenameBlocksToPromptsStacksToFlows do
  @moduledoc """
  Renames all Block/Stack related tables, columns, indexes, and constraints
  to use Prompt/Flow terminology. Data is preserved using ALTER TABLE RENAME.
  """
  use Ecto.Migration

  def up do
    # =====================
    # Step 1: Rename main tables
    # =====================
    execute "ALTER TABLE blocks RENAME TO prompts"
    execute "ALTER TABLE stacks RENAME TO flows"
    execute "ALTER TABLE stacks_blocks RENAME TO flows_prompts"
    execute "ALTER TABLE block_tags RENAME TO prompt_tags"
    execute "ALTER TABLE stack_tags RENAME TO flow_tags"
    execute "ALTER TABLE block_favorites RENAME TO prompt_favorites"
    execute "ALTER TABLE stack_favorites RENAME TO flow_favorites"

    # =====================
    # Step 2: Rename columns in flows_prompts (was stacks_blocks)
    # =====================
    execute "ALTER TABLE flows_prompts RENAME COLUMN block_id TO prompt_id"
    execute "ALTER TABLE flows_prompts RENAME COLUMN stack_id TO flow_id"

    # =====================
    # Step 3: Rename columns in prompt_tags (was block_tags)
    # =====================
    execute "ALTER TABLE prompt_tags RENAME COLUMN block_id TO prompt_id"

    # =====================
    # Step 4: Rename columns in flow_tags (was stack_tags)
    # =====================
    execute "ALTER TABLE flow_tags RENAME COLUMN stack_id TO flow_id"

    # =====================
    # Step 5: Rename columns in prompt_favorites (was block_favorites)
    # =====================
    execute "ALTER TABLE prompt_favorites RENAME COLUMN block_id TO prompt_id"

    # =====================
    # Step 6: Rename columns in flow_favorites (was stack_favorites)
    # =====================
    execute "ALTER TABLE flow_favorites RENAME COLUMN stack_id TO flow_id"

    # =====================
    # Step 7: Rename foreign key constraints on prompts (was blocks)
    # =====================
    execute "ALTER TABLE prompts RENAME CONSTRAINT blocks_user_id_fkey TO prompts_user_id_fkey"

    execute "ALTER TABLE prompts RENAME CONSTRAINT blocks_copied_from_id_fkey TO prompts_copied_from_id_fkey"

    # =====================
    # Step 8: Rename foreign key constraints on flows (was stacks)
    # =====================
    execute "ALTER TABLE flows RENAME CONSTRAINT stacks_user_id_fkey TO flows_user_id_fkey"

    execute "ALTER TABLE flows RENAME CONSTRAINT stacks_copied_from_id_fkey TO flows_copied_from_id_fkey"

    # =====================
    # Step 9: Rename foreign key constraints on flows_prompts (was stacks_blocks)
    # =====================
    execute "ALTER TABLE flows_prompts RENAME CONSTRAINT stacks_blocks_stack_id_fkey TO flows_prompts_flow_id_fkey"

    execute "ALTER TABLE flows_prompts RENAME CONSTRAINT stacks_blocks_block_id_fkey TO flows_prompts_prompt_id_fkey"

    # =====================
    # Step 10: Rename foreign key constraints on prompt_tags (was block_tags)
    # =====================
    execute "ALTER TABLE prompt_tags RENAME CONSTRAINT block_tags_block_id_fkey TO prompt_tags_prompt_id_fkey"

    execute "ALTER TABLE prompt_tags RENAME CONSTRAINT block_tags_tag_id_fkey TO prompt_tags_tag_id_fkey"

    # =====================
    # Step 11: Rename foreign key constraints on flow_tags (was stack_tags)
    # =====================
    execute "ALTER TABLE flow_tags RENAME CONSTRAINT stack_tags_stack_id_fkey TO flow_tags_flow_id_fkey"

    execute "ALTER TABLE flow_tags RENAME CONSTRAINT stack_tags_tag_id_fkey TO flow_tags_tag_id_fkey"

    # =====================
    # Step 12: Rename foreign key constraints on prompt_favorites (was block_favorites)
    # =====================
    execute "ALTER TABLE prompt_favorites RENAME CONSTRAINT block_favorites_user_id_fkey TO prompt_favorites_user_id_fkey"

    execute "ALTER TABLE prompt_favorites RENAME CONSTRAINT block_favorites_block_id_fkey TO prompt_favorites_prompt_id_fkey"

    # =====================
    # Step 13: Rename foreign key constraints on flow_favorites (was stack_favorites)
    # =====================
    execute "ALTER TABLE flow_favorites RENAME CONSTRAINT stack_favorites_user_id_fkey TO flow_favorites_user_id_fkey"

    execute "ALTER TABLE flow_favorites RENAME CONSTRAINT stack_favorites_stack_id_fkey TO flow_favorites_flow_id_fkey"

    # =====================
    # Step 14: Rename indexes on prompts (was blocks)
    # =====================
    execute "ALTER INDEX blocks_is_public_index RENAME TO prompts_is_public_index"
    execute "ALTER INDEX blocks_is_highlighted_index RENAME TO prompts_is_highlighted_index"
    execute "ALTER INDEX blocks_copied_from_id_index RENAME TO prompts_copied_from_id_index"
    execute "ALTER INDEX blocks_search_idx RENAME TO prompts_search_idx"
    execute "ALTER INDEX blocks_name_trgm_idx RENAME TO prompts_name_trgm_idx"
    execute "ALTER INDEX blocks_content_trgm_idx RENAME TO prompts_content_trgm_idx"

    # =====================
    # Step 15: Rename indexes on flows (was stacks)
    # =====================
    execute "ALTER INDEX stacks_is_public_index RENAME TO flows_is_public_index"
    execute "ALTER INDEX stacks_is_highlighted_index RENAME TO flows_is_highlighted_index"
    execute "ALTER INDEX stacks_copied_from_id_index RENAME TO flows_copied_from_id_index"
    execute "ALTER INDEX stacks_search_idx RENAME TO flows_search_idx"
    execute "ALTER INDEX stacks_name_trgm_idx RENAME TO flows_name_trgm_idx"

    # =====================
    # Step 16: Rename indexes on flows_prompts (was stacks_blocks)
    # =====================
    execute "ALTER INDEX stacks_blocks_unique_block_in_stack_index RENAME TO flows_prompts_unique_prompt_in_flow_index"

    # =====================
    # Step 17: Rename indexes on prompt_tags (was block_tags)
    # =====================
    execute "ALTER INDEX block_tags_block_id_tag_id_index RENAME TO prompt_tags_prompt_id_tag_id_index"
    execute "ALTER INDEX block_tags_block_id_index RENAME TO prompt_tags_prompt_id_index"
    execute "ALTER INDEX block_tags_tag_id_index RENAME TO prompt_tags_tag_id_index"

    # =====================
    # Step 18: Rename indexes on flow_tags (was stack_tags)
    # =====================
    execute "ALTER INDEX stack_tags_stack_id_tag_id_index RENAME TO flow_tags_flow_id_tag_id_index"
    execute "ALTER INDEX stack_tags_stack_id_index RENAME TO flow_tags_flow_id_index"
    execute "ALTER INDEX stack_tags_tag_id_index RENAME TO flow_tags_tag_id_index"

    # =====================
    # Step 19: Rename indexes on prompt_favorites (was block_favorites)
    # =====================
    execute "ALTER INDEX block_favorites_user_id_block_id_index RENAME TO prompt_favorites_user_id_prompt_id_index"
    execute "ALTER INDEX block_favorites_user_id_index RENAME TO prompt_favorites_user_id_index"

    execute "ALTER INDEX block_favorites_block_id_index RENAME TO prompt_favorites_prompt_id_index"

    # =====================
    # Step 20: Rename indexes on flow_favorites (was stack_favorites)
    # =====================
    execute "ALTER INDEX stack_favorites_user_id_stack_id_index RENAME TO flow_favorites_user_id_flow_id_index"
    execute "ALTER INDEX stack_favorites_user_id_index RENAME TO flow_favorites_user_id_index"
    execute "ALTER INDEX stack_favorites_stack_id_index RENAME TO flow_favorites_flow_id_index"

    # =====================
    # Step 21: Rename primary key constraints
    # =====================
    execute "ALTER TABLE prompts RENAME CONSTRAINT blocks_pkey TO prompts_pkey"
    execute "ALTER TABLE flows RENAME CONSTRAINT stacks_pkey TO flows_pkey"
    execute "ALTER TABLE flows_prompts RENAME CONSTRAINT stacks_blocks_pkey TO flows_prompts_pkey"
    execute "ALTER TABLE prompt_tags RENAME CONSTRAINT block_tags_pkey TO prompt_tags_pkey"
    execute "ALTER TABLE flow_tags RENAME CONSTRAINT stack_tags_pkey TO flow_tags_pkey"

    execute "ALTER TABLE prompt_favorites RENAME CONSTRAINT block_favorites_pkey TO prompt_favorites_pkey"

    execute "ALTER TABLE flow_favorites RENAME CONSTRAINT stack_favorites_pkey TO flow_favorites_pkey"
  end

  def down do
    # =====================
    # Step 1: Rename primary key constraints back
    # =====================
    execute "ALTER TABLE prompts RENAME CONSTRAINT prompts_pkey TO blocks_pkey"
    execute "ALTER TABLE flows RENAME CONSTRAINT flows_pkey TO stacks_pkey"
    execute "ALTER TABLE flows_prompts RENAME CONSTRAINT flows_prompts_pkey TO stacks_blocks_pkey"
    execute "ALTER TABLE prompt_tags RENAME CONSTRAINT prompt_tags_pkey TO block_tags_pkey"
    execute "ALTER TABLE flow_tags RENAME CONSTRAINT flow_tags_pkey TO stack_tags_pkey"

    execute "ALTER TABLE prompt_favorites RENAME CONSTRAINT prompt_favorites_pkey TO block_favorites_pkey"

    execute "ALTER TABLE flow_favorites RENAME CONSTRAINT flow_favorites_pkey TO stack_favorites_pkey"

    # =====================
    # Step 2: Rename indexes back on flow_favorites
    # =====================
    execute "ALTER INDEX flow_favorites_user_id_flow_id_index RENAME TO stack_favorites_user_id_stack_id_index"
    execute "ALTER INDEX flow_favorites_user_id_index RENAME TO stack_favorites_user_id_index"
    execute "ALTER INDEX flow_favorites_flow_id_index RENAME TO stack_favorites_stack_id_index"

    # =====================
    # Step 3: Rename indexes back on prompt_favorites
    # =====================
    execute "ALTER INDEX prompt_favorites_user_id_prompt_id_index RENAME TO block_favorites_user_id_block_id_index"
    execute "ALTER INDEX prompt_favorites_user_id_index RENAME TO block_favorites_user_id_index"

    execute "ALTER INDEX prompt_favorites_prompt_id_index RENAME TO block_favorites_block_id_index"

    # =====================
    # Step 4: Rename indexes back on flow_tags
    # =====================
    execute "ALTER INDEX flow_tags_flow_id_tag_id_index RENAME TO stack_tags_stack_id_tag_id_index"
    execute "ALTER INDEX flow_tags_flow_id_index RENAME TO stack_tags_stack_id_index"
    execute "ALTER INDEX flow_tags_tag_id_index RENAME TO stack_tags_tag_id_index"

    # =====================
    # Step 5: Rename indexes back on prompt_tags
    # =====================
    execute "ALTER INDEX prompt_tags_prompt_id_tag_id_index RENAME TO block_tags_block_id_tag_id_index"
    execute "ALTER INDEX prompt_tags_prompt_id_index RENAME TO block_tags_block_id_index"
    execute "ALTER INDEX prompt_tags_tag_id_index RENAME TO block_tags_tag_id_index"

    # =====================
    # Step 6: Rename indexes back on flows_prompts
    # =====================
    execute "ALTER INDEX flows_prompts_unique_prompt_in_flow_index RENAME TO stacks_blocks_unique_block_in_stack_index"

    # =====================
    # Step 7: Rename indexes back on flows
    # =====================
    execute "ALTER INDEX flows_is_public_index RENAME TO stacks_is_public_index"
    execute "ALTER INDEX flows_is_highlighted_index RENAME TO stacks_is_highlighted_index"
    execute "ALTER INDEX flows_copied_from_id_index RENAME TO stacks_copied_from_id_index"
    execute "ALTER INDEX flows_search_idx RENAME TO stacks_search_idx"
    execute "ALTER INDEX flows_name_trgm_idx RENAME TO stacks_name_trgm_idx"

    # =====================
    # Step 8: Rename indexes back on prompts
    # =====================
    execute "ALTER INDEX prompts_is_public_index RENAME TO blocks_is_public_index"
    execute "ALTER INDEX prompts_is_highlighted_index RENAME TO blocks_is_highlighted_index"
    execute "ALTER INDEX prompts_copied_from_id_index RENAME TO blocks_copied_from_id_index"
    execute "ALTER INDEX prompts_search_idx RENAME TO blocks_search_idx"
    execute "ALTER INDEX prompts_name_trgm_idx RENAME TO blocks_name_trgm_idx"
    execute "ALTER INDEX prompts_content_trgm_idx RENAME TO blocks_content_trgm_idx"

    # =====================
    # Step 9: Rename foreign key constraints back on flow_favorites
    # =====================
    execute "ALTER TABLE flow_favorites RENAME CONSTRAINT flow_favorites_user_id_fkey TO stack_favorites_user_id_fkey"

    execute "ALTER TABLE flow_favorites RENAME CONSTRAINT flow_favorites_flow_id_fkey TO stack_favorites_stack_id_fkey"

    # =====================
    # Step 10: Rename foreign key constraints back on prompt_favorites
    # =====================
    execute "ALTER TABLE prompt_favorites RENAME CONSTRAINT prompt_favorites_user_id_fkey TO block_favorites_user_id_fkey"

    execute "ALTER TABLE prompt_favorites RENAME CONSTRAINT prompt_favorites_prompt_id_fkey TO block_favorites_block_id_fkey"

    # =====================
    # Step 11: Rename foreign key constraints back on flow_tags
    # =====================
    execute "ALTER TABLE flow_tags RENAME CONSTRAINT flow_tags_flow_id_fkey TO stack_tags_stack_id_fkey"

    execute "ALTER TABLE flow_tags RENAME CONSTRAINT flow_tags_tag_id_fkey TO stack_tags_tag_id_fkey"

    # =====================
    # Step 12: Rename foreign key constraints back on prompt_tags
    # =====================
    execute "ALTER TABLE prompt_tags RENAME CONSTRAINT prompt_tags_prompt_id_fkey TO block_tags_block_id_fkey"

    execute "ALTER TABLE prompt_tags RENAME CONSTRAINT prompt_tags_tag_id_fkey TO block_tags_tag_id_fkey"

    # =====================
    # Step 13: Rename foreign key constraints back on flows_prompts
    # =====================
    execute "ALTER TABLE flows_prompts RENAME CONSTRAINT flows_prompts_flow_id_fkey TO stacks_blocks_stack_id_fkey"

    execute "ALTER TABLE flows_prompts RENAME CONSTRAINT flows_prompts_prompt_id_fkey TO stacks_blocks_block_id_fkey"

    # =====================
    # Step 14: Rename foreign key constraints back on flows
    # =====================
    execute "ALTER TABLE flows RENAME CONSTRAINT flows_user_id_fkey TO stacks_user_id_fkey"

    execute "ALTER TABLE flows RENAME CONSTRAINT flows_copied_from_id_fkey TO stacks_copied_from_id_fkey"

    # =====================
    # Step 15: Rename foreign key constraints back on prompts
    # =====================
    execute "ALTER TABLE prompts RENAME CONSTRAINT prompts_user_id_fkey TO blocks_user_id_fkey"

    execute "ALTER TABLE prompts RENAME CONSTRAINT prompts_copied_from_id_fkey TO blocks_copied_from_id_fkey"

    # =====================
    # Step 16: Rename columns back in flow_favorites
    # =====================
    execute "ALTER TABLE flow_favorites RENAME COLUMN flow_id TO stack_id"

    # =====================
    # Step 17: Rename columns back in prompt_favorites
    # =====================
    execute "ALTER TABLE prompt_favorites RENAME COLUMN prompt_id TO block_id"

    # =====================
    # Step 18: Rename columns back in flow_tags
    # =====================
    execute "ALTER TABLE flow_tags RENAME COLUMN flow_id TO stack_id"

    # =====================
    # Step 19: Rename columns back in prompt_tags
    # =====================
    execute "ALTER TABLE prompt_tags RENAME COLUMN prompt_id TO block_id"

    # =====================
    # Step 20: Rename columns back in flows_prompts
    # =====================
    execute "ALTER TABLE flows_prompts RENAME COLUMN prompt_id TO block_id"
    execute "ALTER TABLE flows_prompts RENAME COLUMN flow_id TO stack_id"

    # =====================
    # Step 21: Rename tables back
    # =====================
    execute "ALTER TABLE flow_favorites RENAME TO stack_favorites"
    execute "ALTER TABLE prompt_favorites RENAME TO block_favorites"
    execute "ALTER TABLE flow_tags RENAME TO stack_tags"
    execute "ALTER TABLE prompt_tags RENAME TO block_tags"
    execute "ALTER TABLE flows_prompts RENAME TO stacks_blocks"
    execute "ALTER TABLE flows RENAME TO stacks"
    execute "ALTER TABLE prompts RENAME TO blocks"
  end
end
