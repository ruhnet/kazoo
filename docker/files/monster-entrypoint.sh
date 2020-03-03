#!/bin/sh

echo "Setting up Monster-UI"
[ ! -d /opt/monster-ui/node_modules ] || npm install

cd /opt/monster-ui

echo "Executing command: $@"
exec "$@"
