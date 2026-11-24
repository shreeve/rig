#!/bin/bash
# marks.sh TAG: groups of sites by their named frames, and their first/last events. Inside cpuq.
R=~/cpuq/tmp/regionmodel; O=$R/out/$1; S=$O/log.hlog.sitenames
{
  awk -F'\t' '$3 $4 ~ /FileLoader\.collect_file/ {print "walk\t" $1}' $S
  awk -F'\t' '$3 $4 ~ /FileLoader\./ {print "loader\t" $1}' $S
  awk -F'\t' '$3 $4 ~ /Binding\.fit/ {print "bindfit\t" $1}' $S
  awk -F'\t' '$3 $4 ~ /bind_in_tasks|bind_into_program|add_bound|merge_bound_files|finish_file|binder\./ {print "bind\t" $1}' $S
  awk -F'\t' '$3 $4 ~ /checker\./ {print "checker\t" $1}' $S
  awk -F'\t' '$3 $4 ~ /process_all_program_files/ {print "papf\t" $1}' $S
} > $O/groups
$R/tools/hmark $O/log.hlog $O/groups
