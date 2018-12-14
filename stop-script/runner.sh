#!/bin/sh

pid=0

trap "echo SIGINT!" SIGINT
trap "kill $pid; echo SIGTERM!" SIGTERM

# run application
redis-server &
pid="$!"

wait $pid
