#!/bin/bash
SP=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/review-place
f=$1; N=/Users/shreeve/Data/Code/rig-place/bin/rig; B=$SP/base/bin/rig
on=$($N run $f 2>&1; echo "rc=$?")
ob=$($B run $f 2>&1; echo "rc=$?")
on=$(echo "$on" | grep -v "^note: the package"); ob=$(echo "$ob" | grep -v "^note: the package")
if [ "$on" != "$ob" ]; then echo "##### RUNDIFF $f"; echo "--- main:"; echo "$ob"; echo "--- branch:"; echo "$on"; fi
if echo "$on" | grep -q "leak\|error\|panic\|rc=[1-9]"; then echo "##### BAD $f"; echo "$on" | head -10; fi
echo "$f ran: $(echo "$on" | tr "\n" "|" | cut -c1-80)" >> .runs
