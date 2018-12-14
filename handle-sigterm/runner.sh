#!/bin/sh
# Make the shell prints some information that helpful for debugging
set -x

# Holding redis pid to be used for killing it later
redis_pid=0

shutdown() {
  # kill redis with SIGTERM
  kill $redis_pid
  # wait for redis to finish it shutdown
  wait $redis_pid
  exit 143 # 128 + 15 -- SIGTERM
}

trap 'shutdown' TERM

# run redis in background
redis-server &
redis_pid=$!

# and wait for it to finish
wait $redis_pid
