#!/bin/bash

TRIES=3

cat 'queries.sql' | while read -r QUERY; do

    echo -n "["

    for i in $(seq 1 $TRIES); do

	  # clear query cache between runs
	  curl -k -X POST 'https://localhost:9200/hits/_cache/clear?pretty' -u "elastic:${PASSWORD}" &>/dev/null

	  JSON="{\"query\" : \"$QUERY\" }"

	  # translate query to DSL
	  DSL=$(curl -s -k -X POST "https://localhost:9200/_sql/translate?pretty" -u "elastic:${PASSWORD}" -H 'Content-Type: application/json' -d"$JSON" ) 

	  # start external timer
	  START=`date +%s.%N`

	  # Run DSL directly through search API
	  ES_RSP=$(curl -s -k -X GET "https://localhost:9200/hits/_search" -u "elastic:${PASSWORD}" -H 'Content-Type: application/json' -d"$DSL" )

	  # run query through SQL API (choosing not to use SQL API directly, because it stalls some queries w/o feedback or cancelling, e.g. 6, 13-15, 17, 31-36)
	  # curl -k -X POST 'https://localhost:9200/_sql?format=txt&pretty' -u "elastic:${PASSWORD}" -H 'Content-Type: application/json' -d"$JSON" #&>/dev/null
	 
	  # calculate timing outside of Elasticsearch (needed for runs through SQL API which does not return the time it took to run)
          END=`date +%s.%N`
          RES=$( echo "$END - $START" | bc -l )

	  # retrieve timing from Elastic Search API "took" parameter and convert to seconds
	  ES_TIME=$(echo $ES_RSP | jq -r '.took')
	  ES_TIME=$(echo "scale=4; $ES_TIME / 1000" | bc)

	  # output ES_TIME to console (it's more accurate), and if ES returned an error, print null
          [[ "$( jq 'has("error")' <<< $ES_RSP )" == "true" ]] && echo -n "null" || echo -n "$ES_TIME"
          [[ "$i" != $TRIES ]] && echo -n ", "

	  # output to result file
          echo "${QUERY_NUM},${i},${ES_TIME}" >> result.csv

    done;

    echo "],"

done;
