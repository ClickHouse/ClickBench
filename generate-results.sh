#!/bin/bash -e

# This script will generate the benchmark results into the HTML page.
# Note: editing HTML with sed may look strange, but at least we avoid using node.js and npm, and that's good.

# Parse extra flag
EXTRA=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --extras)
            EXTRA=$2
            shift 2
            ;;
        *)
            echo "Error: Unknown flag '$1'"
            echo "Usage: $0 [--extras otel]"
            exit 1
            ;;
    esac
done

# Validate extra flag value
if [ "$EXTRA" != "false" ] && [ "$EXTRA" != "otel" ]; then
    echo "Error: Invalid value for --extras flag. Must be 'otel'"
    echo "Usage: $0 [--extras otel]"
    exit 1
fi

(
    sed '/^const data = \[$/q' index.html.template

    FIRST=1
    ls -1 results/*.json | while read file
    do
        [[ $file =~ ^(hardware|versions)/ ]] && continue;

        [ "${FIRST}" = "0" ] && echo -n ','
        jq --compact-output ". += {\"source\": \"${file}\"}" "${file}"
        FIRST=0
    done
    set -o noglob
    echo ']; // end of data'
    echo 'const queries = ['
    FIRST=1
    cat queries.sql | while read query; do
        [ "${FIRST}" = "0" ] && echo -n ','
        echo $query | jq  --raw-input .
        FIRST=0
    done
    
    # Add OTEL queries if --extra=otel
    if [ "$EXTRA" = "otel" ]; then
        if [ -f "queries_otel.sql" ]; then
            # Add comma if there were regular queries before
            
            cat queries_otel.sql | while read query; do
                echo -n ','
                echo $query | jq  --raw-input .
                FIRST=0
            done
        fi
    fi
    
    echo ']; // end of queries'
    sed '1,/^\]; \/\/ end of queries$/d' index.html.template
    set +o noglob
) > index.html
