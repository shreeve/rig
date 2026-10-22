R=/Users/shreeve/Data/Code/rig-rv-docs/bin/rig
cat > "$1.rig"
echo "== $1"
"$R" ${MODE:-run} "$1.rig" 2>&1 | head -${2:-12}
