#!/bin/bash

echo "================================"
echo "SERVER INFORMATION"
echo "================================"

echo "Hostname: $(hostname)"
echo "Date: $(date)"
echo "Uptime: $(uptime -p)"
echo "IP Address: $(hostname -I)"

echo "================================"
echo "DISK USAGE"
echo "================================"

df -h

echo "================================"
echo "MEMORY USAGE"
echo "================================"

free -h
