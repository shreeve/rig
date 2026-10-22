# Cold-path evidence for the oncecall rule / a `cold` marker (json.rig, 2026-10-13)

Calls per parse (utf8_text: strings with a raw byte >= 0x80; number: number tokens):

| file | utf8_text | number |
|---|---|---|
| twitter | 755 of 18,099 strings (4.2%) | 2,109 |
| twitterescaped | 0 of 18,099 | 2,109 |
| canada | 0 of 12 | 111,126 |
| citm_catalog | 108 of 26,604 (0.4%) | 14,392 |
| gsoc-2018 | 0 of 34,128 | 0 |
| github_events | 2 of 1,891 (0.1%) | 149 |

Same structure (one call site, inlined into document's loop), opposite temperature.
Inlining utf8_text: +6.6% twitter, +17.0% twitterescaped, +11.3% citm, +8.6% gsoc, +16.2% github instructions/byte (where it never runs on three files).
Losing number's inlining (document[dense] two instances): canada +22.5% instructions, 13% slower.
Other cold cases: `fail` (error path only); the wsspec run function (4-6% more inlined where never run).
