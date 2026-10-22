# Generate src/parser.zig at build time

Branch codev (pushed, no PR). Rig and Nexus are co-developed, so the generated parser is no longer committed.

- src/parser.zig is untracked and in .gitignore.
- Every build target (install, run, test, oracle) depends on a Nexus step that reads rig.grammar and writes src/parser.zig. Zig caches it on the grammar and Nexus binary contents.
- Nexus is -Dnexus=PATH, else the nearest parent's nexus/bin/nexus. If missing, the build fails with a message giving where it looked and how to get Nexus. Nexus output shows only on failure.
- test/run: parser freshness check, NEXUS and find_nexus removed; test/README.md updated.
- AGENTS.md rule 6, Workflow Nexus paragraph, Map row; also HANDOFF.md, docs/INTERNALS.md, rig.grammar header comment.
- CI (shards.yml): checks out shreeve/nexus at main beside Rig, builds with -Doptimize=safe -Dcpu=baseline, caches the binary keyed on the Nexus commit SHA.

Gates: clean clone built (parser generated, rebuild cached, grammar edit regenerates, missing Nexus fails clearly); ./test/run --delta: 3200 passed, 0 failed, 3 pending.
