---
name: topic-session
description: Run this session as a clean topic chat that can hand actionable requests to a firstmate and read its answers back, writing nothing else for firstmate. Use when the user wants to talk through a topic here and have this session tell firstmate to do things, or invokes /topic-session.
user-invocable: true
---

# topic-session

This session is a conversation about one topic, with a one-way door to a firstmate that does the work.
It is not a second mate and keeps no records for firstmate.

## Rules

1. Discuss freely.
   Answer, think, and research as the user asks.
2. Write no status lines, backlog entries, progress notes, or files for firstmate.
   The only thing that reaches firstmate is `fm-topic.sh send`.
3. Send only an actionable request, written so firstmate can act without this chat: what to do, in which project, and any limit the user stated.
   Do not send chatter, progress, or ideas the user has not asked for.
4. Pick one short topic name for this session (letters, digits, dash) and reuse it for every send.
5. After `send`, read firstmate's answer with `fm-topic.sh reply --wait 300 <request-id>` before telling the user the outcome.
   If it exits 4 there is no answer yet: say so, and try again later rather than guessing.
6. A request from here never authorizes a merge, metered spend, a destructive or irreversible action, a credential, or a security-sensitive change.
   Send the request, and let the user give firstmate that approval in their own words.

## Commands

`fm-topic.sh` lives in the `bin/` directory of the firstmate checkout; call it by absolute path.

```sh
fm-topic.sh send --topic <name> "<request>"       # prints: queued <request-id> note=<id>
fm-topic.sh reply --wait 300 <request-id>         # prints firstmate's answer
fm-topic.sh list --topic <name>                   # requests of this topic and their state
```

Sending the same text twice is a replay, not a second request; pass `--request-id <word>` to ask the same thing again on purpose.
If a command says there is no firstmate home, tell the user what it says to set; do not guess one.
