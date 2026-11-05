#!/bin/bash
# linux-tests.sh DIR: the handoff's endings on Linux, each arm (modes0 without, modes1 with).
cd $1
for v in 0 1; do
  echo "== arm $v"
  for m in ok three exit panic fail; do ./modes$v $m > out.txt 2> err.txt; echo "$m: status $? out=[$(tr '\n' ' ' < out.txt)] err=[$(head -c 60 err.txt | tr '\n' ' ')]"; done
  echo hello | ./modes$v stdin | tr '\n' ' '; echo
  ./modes$v ok | cat; ./modes$v big 1000 | head -1; echo "pipe ${PIPESTATUS[@]}"
  ./modes$v sleep > /dev/null 2>&1 & P=$!; sleep 0.3; kill -TERM $P; wait $P; echo "kill -TERM pid: $?"
  if [ $v = 1 ]; then
    ./modes1 sleep > /dev/null 2>&1 & P=$!; sleep 0.3; C=$(pgrep -P $P); kill -KILL $C; wait $P; echo "child SIGKILL: $?"
    ./modes1 sleep > /dev/null 2>&1 & P=$!; sleep 0.3; C=$(pgrep -P $P); kill -SEGV $C; wait $P; echo "child SIGSEGV: $?"
    ./modes1 sleep > /dev/null 2>&1 & P=$!; sleep 0.3; C=$(pgrep -P $P); kill -KILL $P; wait $P; echo "parent SIGKILL: $?"; sleep 0.2; ps -o pid= -p $C > /dev/null && echo "child still running" || echo "child gone (PDEATHSIG)"
  fi
done
