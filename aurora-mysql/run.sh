#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    for i in $(seq 1 $TRIES); do
        mysql -h "${FQDN}" -u admin --password="${PASSWORD}" test -vvv -e "${query}"
    done;
done;
