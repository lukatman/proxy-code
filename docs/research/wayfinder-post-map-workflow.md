# Wayfinder post-map workflow

Research date: 2026-09-02

## Question

After a Wayfinder map is created, should its decision tickets become implementation tickets directly, and how is the detail gathered during mapping preserved?

## Finding

There are two different milestones:

1. **The charting session is done:** keep invoking `/wayfinder <map issue>` to resolve the map's frontier. Each session normally resolves one decision ticket, records the answer in a resolution comment, closes it, adds a one-line linked gist to the map, and creates any newly visible decision tickets. Continue until no decision tickets or fog remain.
2. **The map is cleared:** run `/to-spec #<map issue>`, then `/to-tickets #<spec issue>`, then implement the resulting tickets.

Do not convert the Wayfinder children directly into build tickets. They are decision tickets and should already be closed when the map clears. The official workflow first collapses the linked decisions into one buildable spec; `to-tickets` then slices that spec into agent-sized, tracer-bullet implementation tickets. Going directly from the map to implementation skips that consolidation and can lose relevant linked detail. The documented exception is an effort that turned out small enough for one implementation session.

Sources: [Wayfinder documentation](https://github.com/mattpocock/skills/blob/main/docs/engineering/wayfinder.md), [Wayfinder skill source](https://github.com/mattpocock/skills/blob/main/skills/engineering/wayfinder/SKILL.md), [to-spec skill source](https://github.com/mattpocock/skills/blob/main/skills/engineering/to-spec/SKILL.md), and [to-tickets skill source](https://github.com/mattpocock/skills/blob/main/skills/engineering/to-tickets/SKILL.md).

## How context is preserved

- The map is an index, not the detail store. Each full decision remains in exactly one closed decision issue as its resolution comment.
- The map's **Decisions so far** section keeps a one-line summary and link to each detailed decision issue. Supporting assets are linked from the relevant issue.
- `/to-spec #<map issue>` reads the map and its linked decisions and consolidates them into one spec issue. That spec is the durable handoff into implementation planning.
- `/to-tickets #<spec issue>` reads the referenced spec's full body and comments, creates implementation tickets with acceptance criteria and blocking edges, and gives each ticket a **Parent** reference to the spec.

The standard templates do **not** guarantee that every implementation ticket links directly to every original Wayfinder decision issue. The normal chain is:

```text
Wayfinder map -> closed decision issues
      |
      v
spec issue -> implementation tickets
```

The original issues remain available through the map, while the spec carries the consolidated decisions needed by fresh implementation sessions.
