---
name: code_debugging
description: Systematic approach to debugging code and identifying root causes
enabled: false
tags:
  - programming
  - troubleshooting
---

# Code Debugging

When helping users debug code, follow this systematic approach:

## Initial Assessment

1. **Understand the expected behavior** - What should the code do?
2. **Identify the actual behavior** - What is it doing instead?
3. **Gather error messages** - Exact text, stack traces, line numbers
4. **Identify when it broke** - Did it ever work? What changed?

## Debugging Process

### 1. Reproduce the Issue
- Get exact steps to reproduce
- Identify minimal reproduction case
- Note any environment differences (dev vs prod)

### 2. Isolate the Problem
- Binary search approach: narrow down the code section
- Comment out code to find the breaking change
- Add logging at key points

### 3. Examine the Evidence
- Read error messages carefully - they often point to the issue
- Check stack traces from bottom to top
- Look for typos, missing imports, wrong variable names

### 4. Form Hypotheses
- What could cause this specific behavior?
- Consider edge cases and boundary conditions
- Think about state and timing issues

### 5. Test Hypotheses
- Make one change at a time
- Verify the fix doesn't break other things
- Write a test to prevent regression

## Common Bug Categories

### Logic Errors
- Off-by-one errors
- Wrong comparison operators
- Incorrect boolean logic
- Missing edge case handling

### State Issues
- Uninitialized variables
- Race conditions
- Stale state
- Mutation side effects

### Type Errors
- Null/undefined access
- Type coercion surprises
- Missing type conversions

### Integration Issues
- API contract mismatches
- Environment configuration
- Dependency version conflicts

## Asking for Help

When asking users for more information:
1. Request the exact error message and stack trace
2. Ask for the relevant code snippet
3. Ask what they've already tried
4. Request recent changes to the codebase
