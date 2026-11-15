# Topic sessions

A topic session is an ordinary Claude session with no project context that the captain uses to talk through one topic.
It can still ask firstmate to do things and read what firstmate answers.
It is not a second mate: it keeps no status lines, backlog entries, or development notes, and firstmate never supervises it.

## The model

The channel is the captain inbox, the same surface the spoken interface uses.
`bin/fm-topic.sh` is a thin client over `bin/fm-inbox.sh`, which stays the single owner of the queue, request-id deduplication, receipts, and reply records.

- `fm-topic.sh send` queues one request with `fm-inbox.sh note --request-id`, so a repeat is a replay.
- Firstmate drains the note like any inbox note and publishes its answer with `fm-inbox.sh reply <note-id>`.
- `fm-topic.sh reply <request-id>` reads that answer back through `fm-inbox.sh receipts`, optionally waiting for it.
- `fm-topic.sh list` shows a topic's requests and whether each is pending, acknowledged, or answered.

Request ids are `topic.<name>.<suffix>`.
The suffix is the explicit `--request-id`, or a hash of the text, so sending the same text again is a replay.
Only `topic.` ids can be read back, so a topic session cannot read replies to the captain's other notes.

## Setup

The topic session needs two things, both outside any project.

1. The firstmate home it talks to, from `FM_TOPIC_HOME`, or from a one-line file at `${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/topic-home`.
   The script never falls back to a guess, ignores `FM_HOME` and the `FM_*_OVERRIDE` variables, and refuses with the exact variable and file path when it finds no home.
2. The skill: install `skills/topic-session` where the session loads skills, and call `fm-topic.sh` by its absolute path in this checkout's `bin/`.

`bin/fm-topic.sh --help` owns the flags, exit codes, and polling variable.

## Trust rule

A request sent from a topic session is the captain's request relayed by a session the captain is talking to.
That session may have read untrusted content, so firstmate never treats such a request as authorization for a merge, metered spend, a destructive or irreversible action, a credential, or a security-sensitive change.
Those still need the captain's own explicit statement.

The rule takes effect without any standing instruction because it travels with the request.
Firstmate recognises a topic request when it drains the inbox note: the note body starts with the origin tag `[topic-session: <name>]`, which also leads the notification line, and ends with a trust notice that states this rule and how to answer.
`fm-topic.sh` writes both, so the topic session's own text cannot omit them.
Firstmate reads the whole note body on drain, which is where the notice appears.
