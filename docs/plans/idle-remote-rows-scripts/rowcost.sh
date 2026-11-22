#!/bin/bash
# per-process cost of remote p4linux rows: ssh client, its /bin/sh parent, its login grandparent
fp(){ v=$(footprint "$1" 2>/dev/null | awk '/phys_footprint:/{print $2; exit}'); echo ${v:-0}; }
rss(){ v=$(ps -o rss= -p "$1" | tr -d ' '); echo ${v:-0}; }
pids=$(ps -axww -o pid=,command= | grep '[s]sh -tt .*p4linux' | awk '{print $1}')
n=0; tcp=0; s_ssh=0; s_sh=0; r_login=0; f_login=0
for p in $pids; do
  n=$((n+1))
  lsof -a -p $p -i TCP >/dev/null 2>&1 && tcp=$((tcp+1))
  sh=$(ps -o ppid= -p $p | tr -d ' '); lg=$(ps -o ppid= -p $sh | tr -d ' ')
  s_ssh=$((s_ssh+$(fp $p))); s_sh=$((s_sh+$(fp $sh))); r_login=$((r_login+$(rss $lg))); f_login=$((f_login+$(fp $lg)))
done
echo "rows=$n own_tcp=$tcp"
echo "phys_footprint KB: ssh=$s_ssh sh=$s_sh login=$f_login (login rss=$r_login, login is root so footprint may read 0)"
