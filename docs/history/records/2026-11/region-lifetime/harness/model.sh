#!/bin/bash
# model.sh TAG: the load's markers from the site names (marks.sh), then hpage. Inside cpuq.
set -eu
R=~/cpuq/tmp/regionmodel; O=$R/out/$1
$R/tools/marks.sh $1 > $O/marks
ls=$(awk '$1=="papf" {print $3}' $O/marks); le=$(awk '$1=="loader" {print $7}' $O/marks); le2=$(awk '$1=="bind" {print $7}' $O/marks)
cat $O/marks
$R/tools/hpage $O/log.hlog $O/m $ls $le $le2 2>&1
