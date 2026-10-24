# Learn Rig

A series of journeys, each a chapter that brings you to understand one
of Rig's big ideas. Each opens on a problem you already have, shows a
whole program before explaining it, and ends with a summary and where to
read more. Every example is checked by Rig's test suite, and each one
shown with its output runs and prints exactly that.

Read them in order; each builds on the ones before it.

| # | Journey | The question it answers |
|---|---|---|
| 01 | [Sigils: a line that says what it does](01-sigils.md) | What does each one-character mark mean, and why are there so few? |
| 02 | [Ownership without a collector](02-ownership.md) | How does Rig free every allocation at a point you can see? |
| 03 | [Errors and optionals: failure you can see](03-errors.md) | How does a program fail without exceptions, and say so where it happens? |
| 04 | [Concurrency without async](04-concurrency.md) | How do you run work at the same time with no colored functions? |
| 05 | [Text done right](05-text.md) | What is a character, and how does Rig keep text both fast and correct? |
| 06 | [The standard library: a tool in an afternoon](06-stdlib.md) | What can you build with what ships? |
| 07 | [Write it once, for every type](07-generics.md) | How does Rig write code once for many types? |
| 08 | [Many types, one contract](08-apis.md) | How do types share a contract, and one list hold many kinds? |
| 09 | [Tests that fail the same way twice](09-tests.md) | How do you test Rig code, concurrent code included, so a failure repeats? |
| 10 | [Safety you can trust](10-safety.md) | What does Rig guarantee, and how do we know? |
| 11 | [What it costs: reading the Zig a program becomes](11-performance.md) | What does a Rig program become, and what does it cost? |
| 12 | A real program, end to end | What does a whole Rig program look like? |

Journeys without a link are being written. Until then,
[WELCOME.md](../../WELCOME.md) introduces the language for programmers
coming from another one, and [SPEC.md](../../SPEC.md) states each rule.
