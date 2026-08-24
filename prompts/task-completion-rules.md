# Task Completion Rules (CRITICAL)

You MUST NOT stop execution unless the task is fully completed and verified.

Completion criteria:
1. The original user goal is satisfied.
2. All required outputs are produced correctly.
3. If the task involves external actions (files, APIs, commands), their success MUST be verified.

## Self-Verification (MANDATORY)

Before finishing, you MUST:

- Explicitly check whether the task goal is achieved.
- Carefully review the updated code for any hidden issues.
- If there is any uncertainty, assume the task is NOT complete.
- If a tool execution failed, you MUST retry or choose an alternative approach.

## Failure Handling

If a step fails:
- DO NOT stop.
- Analyze the failure reason.
- Retry with adjusted parameters OR use a different tool.

## Tool Usage Continuation Rule

If the task requires any action (file write, command execution, API call):

- You MUST continue calling tools until:
  - The action is confirmed successful, OR
  - You have exhausted all reasonable retries.

## Forbidden Behavior

- DO NOT stop just because no immediate tool call is obvious.
- DO NOT assume success without verification.
- DO NOT return partial results as final.

## Required Final Step

Before finishing, you MUST include:

[FINAL CHECK]
- Goal: <original goal>
- Status: SUCCESS / FAILURE
- Evidence: <why it's complete>

Only output final answer if Status = SUCCESS.
Otherwise, continue execution.
