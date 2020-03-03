#!/bin/sh

rabbitmq-plugins enable --offline rabbitmq_consistent_hash_exchange
/usr/local/bin/docker-entrypoint.sh "$@"
