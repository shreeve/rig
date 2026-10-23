# pup's memory rule in the release-slot lock

2026-10-22, consolidation track 4. A proposal for Trig, whose tools these
are; Rig's session does not edit Trig's repository.

## The slip

pup has 30 GB. A Trig release build peaks near 9 GB, and Rig's
`zig build` and `rig build --release` of Trig take as much. The rule
that keeps three such builds from running out of memory at once (start
a release build only with at least 12 GB available and at most one
other release build running) is prose: in Rig's consolidation PLAN, in
the ledger, and in one-off scripts such as
`2026-10/safety-checks/len-map-data/build4.sh`, which polled `free -g`
and `ps` before each step. `tools/release-slot` (and its copy
`/zfs/trig-pup/trial/slot.sh`) waits only for one of its three slots,
so a build started by hand or by a script that forgot the rule takes the
third slot whatever memory is left.

## The proposal

`tools/release-slot` takes a slot only when the rule holds, checked and
taken under one `flock`, so two waiters cannot both see one other build
and both start. The check reads `/proc/meminfo`, so on the Mac (one
slot, no `/proc`) nothing changes. Both numbers can be set:
`TRIG_RELEASE_MIN_GB` (default 12) and `TRIG_RELEASE_MAX_OTHERS`
(default 1). A running build counts by its slot's live holder, as the
lock already judges one. In the slot loop, replace `if mkdir "$path"`
with `if ready && mkdir "$path"`, add these lines before the loop, and
release the gate (`exec 8>&-`) after it, with the hour's limit as now:

```sh
min_gb=${TRIG_RELEASE_MIN_GB:-12} max_others=${TRIG_RELEASE_MAX_OTHERS:-1}
exec 8>"$lock.gate"
ready() {  # with the gate held: enough memory, and few enough builds running
  [ -r /proc/meminfo ] || return 0
  gb=$(awk '/^MemAvailable:/ { print int($2 / 1048576) }' /proc/meminfo) n=0
  for p in "$lock" "$lock".[0-9]*; do
    pid=$(cat "$p/pid" 2>/dev/null) && kill -0 "$pid" 2>/dev/null && n=$((n + 1))
  done
  [ "$gb" -ge "$min_gb" ] && [ "$n" -le "$max_others" ] && return 0
  [ -n "${told:-}" ] || { told=1; echo "release-slot: waiting for ${min_gb} GB available ($gb now) and at most $max_others other build ($n now)" >&2; }
  return 1
}
```

The gate is taken (`flock 8`) at the top of each pass of the loop and
released (`flock -u 8`) before its `sleep 5`, so a waiter never holds it
while it sleeps:

```sh
 while :; do
+  flock 8
   k=0
   ...
-    if mkdir "$path" 2>/dev/null; then
+    if ready && mkdir "$path" 2>/dev/null; then
   ...
   done
+  flock -u 8
   [ $waited -lt 3600 ] || ...
   sleep 5
   waited=$((waited + 5))
 done
+exec 8>&-
 trap 'rm -rf "$held"' EXIT
```

Tried on pup on 2026-10-22, patched into a copy of `tools/release-slot`
with a temporary `HOME` and three slots: with no slot held it ran at
once; with two slots held by live processes it waited, and said so once;
when one of them ended it ran; with `TRIG_RELEASE_MIN_GB=999` it waited
on memory.

## What it does not cover

A build that takes no slot (a bare `zig build` on pup) is not counted.
Rig's and Trig's scripts on pup take a slot for every release build;
`tools/pup-rig` and `tools/full-main` already do.
