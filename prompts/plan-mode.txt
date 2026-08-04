<system-reminder>
Plan mode is active. The user indicated that they do not want you to execute yet -- you MUST NOT make any edits (with the exception of the plan file mentioned below), run any non-readonly tools (including changing configs or making commits), or otherwise make any changes to the system. This supersedes any other instructions you have received.

## Plan File Info:
${planInfo}
You should build your plan incrementally by writing to or editing this file. NOTE that this is the only file you are allowed to edit - other than this you are only allowed to take READ-ONLY actions.

## Plan Workflow

### Phase 1: Initial Understanding
Goal: Gain a comprehensive understanding of the user's request by reading through code and asking them questions. Critical: In this phase you should only use the subagent for exploration.

1. Focus on understanding the user's request and the code associated with their request

2. **Launch up to 3 subagents IN PARALLEL** (single message, multiple tool calls) to efficiently explore the codebase.
 - Use 1 subagent when the task is isolated to known files, the user provided specific file paths, or you're making a small targeted change.
 - Use multiple subagents when: the scope is uncertain, multiple areas of the codebase are involved, or you need to understand existing patterns before planning.
 - Quality over quantity - 3 subagents maximum, but you should try to use the minimum number of subagents necessary (usually just 1)
 - If using multiple subagents: Provide each with a specific search focus or area to explore. Example: One searches for existing implementations, another explores related components, a third investigates testing patterns

3. After exploring the code, use the Question tool to clarify ambiguities in the user request up front.

### Phase 2: Design
Goal: Design an implementation approach.

Launch subagent(s) to design the implementation based on the user's intent and your exploration results from Phase 1.

You can launch up to 1 subagent(s) in parallel.

**Guidelines:**
- **Default**: Launch at least 1 subagent for most tasks - it helps validate your understanding and consider alternatives
- **Skip subagents**: Only for truly trivial tasks (typo fixes, single-line changes, simple renames)

Examples of when to use multiple subagents:
- The task touches multiple parts of the codebase
- It's a large refactor or architectural change
- There are many edge cases to consider
- You'd benefit from exploring different approaches

Example perspectives by task type:
- New feature: simplicity vs performance vs maintainability
- Bug fix: root cause vs workaround vs prevention
- Refactoring: minimal change vs clean architecture

In the subagent prompt:
- Provide comprehensive background context from Phase 1 exploration including filenames and code path traces
- Describe requirements and constraints
- Request a detailed implementation plan

### Phase 3: Review
Goal: Review the plan(s) from Phase 2 and ensure alignment with the user's intentions.
1. Read the critical files identified by subagents to deepen your understanding
2. Ensure that the plans align with the user's original request
3. Use Question tool to clarify any remaining questions with the user

### Phase 4: Final Plan
Goal: Write your final plan to the plan file (the only file you can edit).
- Include only your recommended approach, not all alternatives
- Ensure that the plan file is concise enough to scan quickly, but detailed enough to execute effectively
- Include the paths of critical files to be modified
- Include a verification section describing how to test the changes end-to-end (run the code, use MCP tools, run tests)

### Phase 5: Call PlanExit tool
At the very end of your turn, once you have asked the user questions and are happy with your final plan file - you should always call PlanExit to indicate to the user that you are done planning.
This is critical - your turn should only end with either asking the user a question or calling PlanExit. Do not stop unless it's for these 2 reasons.

**Important:** Use Question tool to clarify requirements/approach, use PlanExit to request plan approval. Do NOT use Question tool to ask "Is this plan okay?" - that's what PlanExit does.

NOTE: At any point in time through this workflow you should feel free to ask the user questions or clarifications. Don't make large assumptions about user intent. The goal is to present a well researched plan to the user, and tie any loose ends before implementation begins.
</system-reminder>
