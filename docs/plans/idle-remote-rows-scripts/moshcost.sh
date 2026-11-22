#!/bin/bash
# cost of the mosh probe row: Mac process chain, presentation stream, p4linux mosh-server
fp(){ footprint "$1" 2>/dev/null | awk '/phys_footprint:/{print $2, $3; exit}'; }
for p in $(pgrep mosh-client); do
  echo "mosh-client $p: $(fp $p) cputime=$(ps -o time= -p $p)"
  pp=$p; for i in 1 2 3 4; do pp=$(ps -o ppid= -p $pp | tr -d ' '); [ "$pp" = 1 ] || [ -z "$pp" ] && break; echo "  parent $pp $(ps -o comm= -p $pp) footprint: $(fp $pp) rss=$(ps -o rss= -p $pp)"; done
  lsof -a -p $p -i 2>/dev/null | tail -n +2 | awk '{print "  socket", $8, $9}'
done
echo "presentation ssh for probe: $(ps -axww -o command= | grep -c '[z]mx present 4662535B')"
ssh p4linux 'for p in $(pgrep -f "mosh-server"); do echo "p4linux mosh-server $p PSS_KB=$(awk "/^Pss:/{print \$2}" /proc/$p/smaps_rollup) $(tr "\0" " " </proc/$p/cmdline | cut -c1-80)"; done' 2>&1 | grep -vE 'ControlSocket|mux_client'
