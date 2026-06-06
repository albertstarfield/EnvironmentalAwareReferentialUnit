#!/bin/bash
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd /usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon
exec ./bin/earu_daemon
