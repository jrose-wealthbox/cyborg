I'd like an "executive summary dashboard" skill called CYBORG.

The idea is to show me as much information as possible at a glance, with a focus on actions.

## Design Notes

- Repo for this skill is: https://github.com/jrose-wealthbox/cyborg
- Docs go in ./docs
- I am the only user, this is a personal dashboard
- Keep track of the last time the executive summary was run
- The final line of the output should be a reminder on the magic LLM command I need to type to edit this skill
- All items should be hyperlinks when possible
- Should be able to work from a desktop app like Claude Code, or a TUI app like Claude Code CLI
- If problems are encountered
  - Examples: missing authorization, or network errors when attempting to access a needed resource such as Gmail or GCal
  - DISPLAY BIG WARNINGS marked with ⚠️ at the top of the summary. Include steps to remedy the issue.
  - Fail fast and loudly
- Use cheap parallel subagents to perform mechanical tasks (e.g. fetching notifications) and summarization tasks. "Cheap" means `luna` or `haiku`
- Configuration should be easily accessible and human readable in .toml or even just Markdown lists
  - Many things listed below will be tweaked and reconfigured as I iterate on this skill
  - Any "magic numbers" or "magic strings" such as URLs or repo names are good candidates for configurability
- The overall goals are the following. Consider them at all times
  - High information density
  - High "scan-ability"
    - Action required items should be visibly prominent
- Don't use emoji unless at least one of the following is true
  - Specifically specified in this document
  - If one appears in a quoted source, such as an email
- This skill should be provider agnostic. I use both Claude and OpenAI currently.
- Be flexible: the installed skills and data sources may vary over time based on which MCPs, skills, and plugins have been installed or removed. Scan this list at startup on each run and use it to inform all future CYBORG runs
- Model choice
  - Use a "medium" model like Terra (OpenAI) or Sonnet (Anthropic) as the orchestrator
  - Use a subagent w/ a cheap model like Luna (xhigh effort) or Haiku (Anthropic) for purely mechanical tasks and simple summarization
  - Specific features below may include suggestions for specific model choices

## Execution

- Execute automatically (in desktop apps only)
  - On weekdays
    - at 8AM
    - at noon
    - at 3PM
- Can be executed any time, ad-hoc from TUI or desktop by invoking the appropriate skill

## Execution Environment

- Target audience is me only
- You can assume the following about the execution environment
  - MacOS
  - Ruby 4.x is available
  - SQLite can be used
- Implement as much as possible in Ruby, I might like to re-use it. This will also aid in LLM agent agnosticism.

## Performance Goals / Caching

CYBORG should not take more than 1-2 minutes to run, with the possible exception of the "Reflection" items below.

Suggest Ruby 4.x and SQLite for implementation. If you have alternative ideas let me know.

All non-trival items should be cached. I should be able to invoke CYBORG 100 times in rapid succession without incurring additional token costs.

A run of CYBORG should not cost more than $5 in tokens, including subagents. STOP AND TERMINATE ALL SUBAGENTS IF THIS THRESHOLD IS EXCEEDED

Current pricing. Look this up at least once per 7 days to get updated pricing
- Anthropic: https://platform.claude.com/docs/en/about-claude/pricing
- OpenAI: https://developers.openai.com/api/docs/pricing

Keep a log (SQlite) of all tokens spent in each session, with separate rows (tied to the orchestration session that spawned them) for subagent sessions.

Default caching TTL is 30 minutes. Some items below may specify other TTLs.

An optional command, `cyborg-no-cache` will empty all caches, fetching all information from source, except for items with TTLs of >= 3 hours (such as "Reflection:" items which are expected to be more expensive)

Another optional command, `cyborg-no-cache-even-expensive` will truly empty all caches, regardless of TTL

We should regularly

## Relevant Timeframe

- "Business day" means our working hours which are generally 9AM-5PM, Mon-Fri
- Unless otherwise noted, the relevant timeframe for executive summary items is "the beginning of the previous business day to the end of the next business day"
  - Begins: 12:00AM of the previous business day
  - Ends: 11:59PM of the next business day
- Days off and national holidays don't count as business days
- Examples
  - Current day/time: 3PM Wednesday
    - Timespan would be 12:00AM Tuesday through 11:59PM Thursday
  - Current day/time: 8AM Monday
    - Timespan would be 12:00AM of the previous Friday through 11:59PM Tuesday
  - Current day/time: 7PM Friday
    - Timespan would be 12:00AM Thursday through 11:59PM the following Monday

## What to show

- Gmail
  - Pending action items
  - High priority unread emails
- Gcal
  - Upcoming events today, as well as the next 2 business days
  - Calendar items designated "Task" (as opposed to "Event") in the next 14 business days
- Slack
  - Summarize conversations in my subscribed channels
  - List @mentions of my username
  - List action items
- Github
  - Action items from my inbox, essentially https://github.com/notifications
    - Include:
      - Pull requests from others awaiting my review
      - Comments on my PRs, or replies to comments I've posted on others' PRs
    - Exclude:
      - CI failures
- Linear
  - Issues assigned to me
  - Comments addressed to me on any issue
  - @mentions of me

## Misc

- Hacker News
  - A "popular story" is one with >=300 upvotes or >=300 comments
    - These should be denoted with 👀
  - Show all "popular stories" on the front page of HN https://news.ycombinator.com/news
  - If there are < 3 "popular stories" then just round out the list with the 3 most popular stories on HN
  - Each item should show the HN story title, hyperlinked to the target URL of the story. Include a second link to the HN discussion.
  - Each item should show the number of upvotes and comments
  - Examples
    - `Apple announces all computers are free (234/4983)`
      - "Apple announces all computers are free" should be a hyperlink to the original item on apple.com
      - 234 is the number of upvotes
      - 4983 is the number of commentds
      - "(234/4983)" is a hyperlink to the HN discussion

## Additional design notes

- All items should show a compact age indicator: `4m` for something that is 4 minutes old, `34d` for something 34 days old.
- Show a 🆕 next to items that meet any of the following criteria
  - They are newer than the last time the agent was run
  - They are 2-4 hours old
- Show 🔥 next to items that are 30-90 minutes old (takes precedence over 🆕)
- Show 🔥🔥 next to items that are 0-30 minutes old (takes precedence over 🆕 and 🔥)
- Show 🚨 next to pending action items (this is independent of 🆕 and 🔥 and 🔥🔥 and can display alongside them)


## Reflection: My actions

This section is meant to serve as a reminder and summary of what *I* have done. This sort of review helps many, including me, to consolidate memories.

Use ALL available information sources available to you, including but not limited to ones specifically listed below in this section or elsewhere in this document.

The available sources of information my change from run to run, as plugins and MCP servers are added and removed.

- Emphasize:
  - Code I committed
  - Slack messages I sent
  - Emails I sent
- Highly emphasize:
  - "Victories" such as PRs that were merged
  - Tasks completed
  - Linear issues closed
- Deemphsize or omit entirely
  - Things others did or said
- Things to include
  - LLM chats
- Chrome browser history
  - Separate into categories
    - "Work"
      - Directly work-related (anything with wealthbox in the URL, etc)
    - "Software Engineering"
      - General software engineering related reading such as Hacker News, Daring Fireball, etc
      - Subreddits and posts in subreddits specifically geared toward software engineering, like r/ruby
    - "Non-work"
      - Generally anything else - gaming subreddits, Amazon, Slickdeals, etc
- Specific example: git & Github
  - For each branch of https://github.com/starburstlabs/crm-web that is authored by me, show the following (grouped by branch)
    - Show the number of commits and lines of code committed
    - Create a summary of my work, based on the content of the commits as well as any LLM chat sessions visible to you. Note that some work may have been done "by hand" or by other agents. Create the best summary you can
  - Notes
    - This includes all active branches, as well as branches that were closed/merged during the relevant timeframe
    - If there was no activity on a branch, omit it entirely
    - Which repos to consider?
      - crm-web
        - This is the primary focus
          - Local instances of crm-web may be found in the following locations
          - (Worktrees) /Users/john/.superset/worktrees/*
          - /Users/john/code/crm-web
      - also include
        - All other repos under /Users/john/code
        - All other worktrees under crm-web

Cache TTL: 4 hours

## Reflection: Trends, Insights, Recommendations

Synthesize trends, insights, and recommendations based on ALL available information sources available to you, including but not limited to ones specifically listed below in this section or elsewhere in this document. Emphasize more recent items in your analysis.

The available sources of information my change from run to run, as plugins and MCP servers are added and removed.

You may examine data as old as 6 months if you feel it is appropriate.

Do not "force" insights, trends, or recommendations. It is acceptable to say "I don't have any right now" if signal is too weak.

Insights, trends, and recommendations should include a confidence estimate based on signal strength

Use a high-end subagent: Sol or Opus for this task.

Cache TTL: 1 day

## Open questions

- Can we trigger desktop notifications, for new pending action items?
- How do we permanently mark an action item as complete, if there is no programmatic way for the skill to autonomously determine it is complete? For example, suppose I have an email telling me to shave my head. The skill has no way to know if I've shaved my head.
- What potential data sources, potentially accessible to you, am I not considering?
- How should we handle secrets such as auth tokens? Ideally, this app should not be in the business of storing them.... but we need them to operate....

## Future goals

I'd like this to eventually be accessible via the web. Separate "presentation", "retrieval", and "analysis" tasks as much as possible, as there may be different methods of presentation in the future.