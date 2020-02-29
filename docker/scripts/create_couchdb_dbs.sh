#!/bin/sh

COUCH_IP="${1:-localhost}"
COUCH_PORT="${2:-5984}"

echo ":: Intializing database for http://$COUCH_IP:$COUCH_PORT"

curl -iX PUT "http://$COUCH_IP:$COUCH_PORT/_global_changes"
curl -iX PUT "http://$COUCH_IP:$COUCH_PORT/_replicator"
curl -iX PUT "http://$COUCH_IP:$COUCH_PORT/_metadata"
curl -iX PUT "http://$COUCH_IP:$COUCH_PORT/_users"
