# Third-party JSON test data

`tools/fetch-json-data.sh` downloads these files here. Git ignores them
(only this README is tracked), and the script checks each against the
sha256 it pins. The `checker` and `corpus` groups of `./test/run json` read
them (`test/json/README.md`).

| Directory | Files | Source | Pinned commit | License |
|---|---|---|---|---|
| `simd-json/` | `pass/`, `fail/`: JSON_checker's test files (`pass01.json`, `fail02.json`, ...), 16 and 78 files, and `crash/`: 38 fuzzer inputs | [simd-lite/simd-json](https://github.com/simd-lite/simd-json), `data/` | `bd1ccfad79ea4ff2f89310fad483365c3f450d04` | simd-json: Apache-2.0 or MIT, at your option |
| `simd-json/` | 17 benchmark documents beside them: `twitter`, `twitterescaped`, `canada`, `citm_catalog`, `gsoc-2018`, `github_events`, `apache_builds`, `marine_ik`, `mesh`, `mesh.pretty`, `numbers`, `random`, `log`, `hdfs_log`, `instruments`, `update-center`, `event_stacktrace_10kb` | the same `data/` directory | the same | the same repository's license; they are the benchmark documents JSON parsers commonly share, which the repository carries without a license of their own |
| `simdjson/` | `twitter`, `citm_catalog`, `example_config`, `recipe_book` (`.json`) | [simdjson/simdjson](https://github.com/simdjson/simdjson), `jsonexamples/` | `7f6f8dca84c3c9129b8a4506d55a4ae1c16024f0` | simdjson: Apache-2.0 or MIT, at your option |

The JSON_checker files come from json.org's test suite. Neither
repository states a license for those files apart from its own, so Rig
does not copy them into its tree: the script fetches them and the tests
only read them. They are test inputs, never part of `std.json` or of a
release.

To change a pin, edit `tools/fetch-json-data.sh` (the commit in a URL, and
the sha256 of each file that changed) and this table together.
