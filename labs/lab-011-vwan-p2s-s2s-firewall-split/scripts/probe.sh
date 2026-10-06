#!/bin/bash
# lab-011: runs on a test VM via az vm run-command. Data-plane probe to the app VM.
# __TARGET__ is replaced by inspect.ps1 before the script is sent.
T='__TARGET__'
if ping -c 3 -W 2 "$T" >/dev/null 2>&1; then echo "PING=OK"; else echo "PING=FAIL"; fi
if timeout 5 bash -c "</dev/tcp/$T/22" >/dev/null 2>&1; then echo "TCP22=OK"; else echo "TCP22=FAIL"; fi
echo "ROUTE_GET=$(ip route get "$T" 2>/dev/null | head -1)"
