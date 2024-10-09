#!/bin/bash -e

# This script will substitute the benchmark results into the HTML page.
# Note: editing HTML with sed may look strange, but at least we avoid using node.js and npm, and that's good.

# This is needed on Mac OS. Do `brew install coreutils`.
[ -n "$HOMEBREW_PREFIX" ] && PATH="${HOMEBREW_PREFIX}/opt/coreutils/libexec/gnubin:${PATH}"

(
    gsed '/^const data = \[$/q' index.html

    FIRST=1
    LANG="" ls -1 */results/*.json | while read file
    do
        [[ $file =~ ^(hardware|versions)/ ]] && continue;

        [ "${FIRST}" = "0" ] && echo -n ','
        jq --compact-output ". += {\"source\": \"${file}\"}" "${file}"
        FIRST=0
    done

    echo ']; // end of data'
    gsed '0,/^\]; \/\/ end of data$/d' index.html

) > index.html.new

mv index.html index.html.bak
mv index.html.new index.html
