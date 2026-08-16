# Development ledger (Korean)

**The files in this directory are written in Korean.** Everything else in this
repository is in English; this is the one deliberate exception.

## What this is

These are session-to-session handoff documents from the development that preceded
publication — raw measurement logs, hypotheses in the order they were formed, the
ones that were refuted and why, and the reasoning as it actually happened. They are
a working ledger, not a finished document.

| File | Contents |
|---|---|
| `handoff-v17.md` | the main ledger through v13-v17: the failure model as it was worked out, the observation tables, the rejected hypotheses |
| `layer7-cache-coherency.md` | the Layer 7 measurement ledger — staleness by read pattern, the traffic comparison, the bistability observations |

## Why it stays in Korean

Two reasons, both practical.

Its findings are **already distilled into the English documents**. Everything you
need in order to use, install or debug this project is in
[failure-model.md](../failure-model.md), [decisions.md](../decisions.md) and
[operations.md](../operations.md). What is only here is the path that was taken to
reach those conclusions.

And the value of this material lies in **the precision of its claims** — which
hypothesis was refuted by which measurement. That is exactly the kind of content a
translation degrades quietly, and it is roughly half of all the documentation in
this repository by volume. Leaving it as it is beats a translation nobody reviewed.

## If you need something from here

The English documents cite this ledger wherever it matters, so start there. If you
still need a specific passage, the terminology table in the repository's
[CLAUDE.md](../../CLAUDE.md) maps the Korean terms used here onto the English ones
used everywhere else, which makes machine translation of a section considerably
more reliable.
