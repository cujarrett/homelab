# Matt Jarrett Blog Writing Style Guide

## Core Writing Identity

Write as an engineer documenting a learning journey, not as an expert teaching a lesson.

The story is never:

> Here's how platform engineering works.

It's:

> Here's the weird thing I built, why I built it, what broke, and what I learned.

The reader discovers the lesson alongside the author.

---

## Voice

### Curious over authoritative

Prefer:
- I wanted to understand...
- I didn't understand why...
- I'm starting to understand...
- What I actually learned...

Explain advanced concepts through discovery rather than expertise.

### Self-deprecating but not insecure

Use humor that highlights enthusiasm:
- Spending $1,500 to save $7/month.
- Building a data center because of a series of "reasonable decisions."
- Learning platform engineering through a sump pump.

### Conversational engineering

Write the way engineers talk after a meeting.

Short sentences.

Occasional fragments.

Example:

> The platform worked. There was just one issue. I was the only person who could use it.

---

## Structure

### 1. Personal hook

Start with a concrete moment.

Not an abstract topic.

Examples:
- Tiny Raspberry Pi screws.
- Spending $1,500 to save $7.
- Looking at a sump pump.

### 2. Escalation

The project starts simple.

Then spirals.

### 3. Explain the technical concept

Explain concepts through the project.

Bad:
> Crossplane is an open-source control plane framework...

Good:
> I wanted to deploy WordPress with a single YAML file. Crossplane was the thing that made that possible.

### 4. Show real implementation

Include:
- Architecture
- YAML
- Topology
- Real implementation details

### 5. Unexpected outcome

Reveal a broader lesson than the original project.

### 6. What I Actually Learned

End with a section titled:

## What I Actually Learned

Use concise observations that generalize beyond the project.

---

## Sentence Style

### Short paragraphs

Most paragraphs are 1–4 sentences.

### Define acronyms on first use

Expand an acronym inline the first time it appears. Never use it cold.

Example:
- Wrong: "The platform rotates SVIDs before they expire."
- Right: "The platform rotates SVIDs — SPIFFE Verifiable Identity Documents — before they expire."

After the first use, the short form is fine.

### Contrast statements — one per post

The `X isn't Y. It's Z.` shape is the strongest move in this guide and the easiest to
overuse. The homelab post used it eight times, and readers called it out by name:
"the writing constantly avoids saying what you're trying to say and wastes time
instead talking about everything you're not saying."

One per post. Spend it on the actual thesis, not on transitions.

Examples worth spending it on:
- The cloud isn't expensive. Ignorance is.
- The platform worked. There was just one issue.
- In theory, it was self-service. In practice, it was YAML.

Everywhere else, say the thing directly. "The computers were never the expensive part"
becomes "The rack, cooling, and cable management cost more than the computers."

### Punchline sentences

Occasionally use short standalone lines.

Examples:
- Entirely unnecessary. Completely worth it.
- Done.

### Em dash and hyphen discipline

Em dashes and certain hyphenated constructions are AI writing smells. Avoid them.

**Em dash (`—`): one per post. Count them before publishing.**

AI overuses it to staple two thoughts together instead of choosing the right punctuation. Use a period, comma, or colon instead.

- Wrong: "It works — it's also unnecessary."
- Right: "It works. It's also unnecessary."

This is the highest-signal tell and the easiest to check. The three posts nobody
complained about hold 1, 3, and 4 em dashes. The homelab post holds 17.

The one you keep should be a genuine parenthetical aside that would be awkward in parentheses.

**Hyphenated adverb–adjective compounds:** "well-documented," "self-service," "long-lived" — fine when they precede a noun. Drop the hyphen after a verb ("it is well documented"). Don't manufacture compound modifiers for their own sake.

**Watch for:** "purely certificate-based," "certificate-based approach," "zero-wiring design" — these read like generated prose. Rewrite as plain sentences.

---

## Technical Philosophy

Technology is interesting because it teaches something.

Move discussion from implementation toward interfaces and APIs.

Focus on products over infrastructure.

Developers want outcomes, not Kubernetes objects.

My homelab started as a place to learn Platform Engineering.

---

## Reusable Prompt

Write in Matt Jarrett's engineering blog style.

Start with a concrete, personal moment rather than a technical explanation.

Write as an engineer learning something, not an expert teaching it. Use curiosity and discovery as the narrative driver.

Explain technical concepts through a real project. The project should begin with a practical goal, escalate into something larger than intended, and reveal an unexpected lesson.

Use short paragraphs, conversational language, and occasional self-deprecating humor.

Hard limits, because these three patterns are what make writing read as AI-generated:
one em dash in the whole post, one "X isn't Y. It's Z." contrast in the whole post, and
no sentences that describe the post rather than advancing it ("This is the story of",
"Here's the thing"). Open with a concrete noun, not a frame.

Include real implementation details, architecture decisions, code snippets, YAML, or configuration where relevant. Make the project feel real and reproducible.

Avoid marketing language, buzzwords, and corporate thought leadership tone.

End with a section titled "What I Actually Learned" containing several concise observations that generalize beyond the project itself.

The underlying theme should be that building things is a vehicle for understanding systems, abstractions, and platform design.
