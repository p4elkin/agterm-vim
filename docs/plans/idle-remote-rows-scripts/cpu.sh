#!/bin/bash
# cumulative CPU seconds of remote-row ssh clients, mux masters, and agterm, with their ages
tosec(){ awk -F'[:.-]' '{ if (NF==4) print $1*60+$2; else if (NF==5) print $1*3600+$2*60+$3; else print $1*86400+$2*3600+$3*60+$4 }' <<<"$1"; }
cl=0; n=0; for p in $(ps -axww -o pid=,command= | grep '[s]sh -tt .*p4linux' | awk '{print $1}'); do t=$(ps -o time= -p $p | tr -d ' '); cl=$(echo "$cl + $(awk -F: '{print $1*60+$2}' <<<"$t")" | bc); n=$((n+1)); done
echo "ssh clients: n=$n cpu_seconds_total=$cl"
ps -axo pid,etime,time,command | grep '[a]910106c.*\[mux\]'
ps -o pid,etime,time,comm -p "${1:?agterm pid}"
