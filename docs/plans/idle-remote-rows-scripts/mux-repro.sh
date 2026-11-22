#!/bin/bash
# usage: mux-repro.sh <soft-fd-limit> <work-dir>. Reproduce: a mux master's session capacity under a given soft fd limit (private control path, one TCP)
LIM=$1; D=$2; CP=/tmp/mxr-$LIM; N=120
bash -c "ulimit -n $LIM; exec ssh -fNM -S $CP -o ControlPersist=90 -o BatchMode=yes p4linux" 2>$D/master-$LIM.err
M=$(pgrep -f "ssh.*-S $CP" | head -1)
for i in $(seq 1 $N); do
  ssh -S $CP -o ControlMaster=no -o HostName=127.0.0.1 -o Port=9 -o ConnectTimeout=1 -o BatchMode=yes p4linux 'echo ok; sleep 20' >$D/c-$LIM-$i.out 2>$D/c-$LIM-$i.err </dev/null &
done
sleep 6
ok=$(cat $D/c-$LIM-*.out | grep -c ok); bp=$(cat $D/c-$LIM-*.err | grep -c 'Broken pipe')
fds=$(lsof -p $M 2>/dev/null | awk '$4 ~ /^[0-9]+[urw]/' | wc -l | tr -d ' ')
echo "soft limit $LIM: $ok of $N sessions ok, $bp 'Broken pipe', master fds=$fds"
cat $D/c-$LIM-*.err | sort | uniq -c | sort -rn | head -3
wait; ssh -S $CP -O exit p4linux 2>/dev/null
