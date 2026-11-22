#!/bin/bash
# per-surface cost slope in an isolated agterm instance: idle empty surfaces, then surfaces with scrollback
P=$1; SOCK=/tmp/agp/agterm.sock
m(){ f=$(footprint $P | awk '/phys_footprint:/{print $2; exit}'); g=$(footprint $P | awk '/graphics\)$/{print $1$2}' | tr '\n' ' '); t=$(ps -M -p $P | tail -n +2 | wc -l | tr -d ' '); c=$(ps -o time= -p $P | tr -d ' '); echo "$1: footprint_MB=$f threads=$t cputime=$c graphics=[$g]"; }
m "1 session"
for i in $(seq 1 20); do agtermctl session new --socket $SOCK --no-select --name idle$i --command "/bin/sh -c 'exec cat'" >/dev/null; done
sleep 90; m "21 sessions (20 idle empty)"
for i in $(seq 1 20); do agtermctl session new --socket $SOCK --no-select --name sb$i --command "/bin/sh -c 'seq -f \"line %06g lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor\" 1 20000; exec cat'" >/dev/null; done
sleep 90; m "41 sessions (20 more with 20000-line scrollback)"
sleep 60; m "41 sessions, 60 s later (idle CPU check)"
