#!/bin/bash

trap ctrl_c INT

CPU_HIGH=12
CPU_LOW=10
RAM_HIGH=51539607552
RAM_LOW=42949672960

apt-get install -y python3-pip
python3 -m venv myenv
source myenv/bin/activate
pip install ytsaurus-client --break-system-packages
pip install ytsaurus-yson --break-system-packages

function ctrl_c() {
        echo "Exiting benchmark. Ctrl+C"
        exit 1
}

throbber() {
    local pid=$1
    local sp="\|/-"
    local i=0

    while kill -0 $pid > /dev/null; do
        printf "\rWaiting... %c" "${sp:$i:1}"
        ((i = (i + 1) % 4))
        sleep 0.1
    done
    printf "\rWaiting... Done!\n"
}


stop_public_clique() {
	yt clickhouse ctl --address $YT_CONTROLLER --proxy $YT_PROXY --cluster-name $CLUSTER_NAME stop *ch_public
}

create_clique() {
	yt clickhouse ctl create --speclet-options "{"active" = %true;"enable_geodata" = %false;"family" = "chyt";"instance_count" = 1;"instance_cpu" = 12;"instance_total_memory" = 51539607552;"pool" = "research";"restart_on_speclet_change" = %true;"stage" = "production";}" --address $YT_CONTROLLER --cluster-name $CLUSTER_NAME clickbench
}

insert_data() {
        yt query --settings '{"clique"="clickbench"}' --format json --async chyt "$(cat fill_data.sql)" > fill_query_id
}

data_filling_waiting() {
        while true; do
                COUNT=$(yt clickhouse execute --alias *clickbench 'select count(*) as c from `//home/hits`')
                if [[ "$COUNT" == 99997497 ]]; then
                        yt abort-query $(cat fill_query_id)
                        break
                else
                        sleep 60
             fi
        done
}


fill_data() {
command time -f '%e' yt clickhouse execute "$(cat create.sql)" --alias *clickbench --proxy $YT_PROXY
insert_data
data_filling_waiting &
throbber $!
yt sort --src //home/hits --dst //home/hits --sort-by "CounterID" --sort-by "EventDate" --sort-by "UserID" --sort-by "EventTime" --sort-by "WatchID" --proxy $YT_PROXY
}


check_ready() {
        TOTAL_JOBS=$(yt list-operations --proxy $YT_PROXY --filter clique --filter clickbench --state running --format json | jq .operations[0].brief_progress.jobs.total)
        RUNNING_JOBS=$(yt list-operations --proxy $YT_PROXY --filter clique --filter clickbench --state running --format json | jq .operations[0].brief_progress.jobs.running)
        STATE=$(yt clickhouse ctl status --address $YT_CONTROLLER --cluster-name $CLUSTER_NAME clickbench | grep "state" | head -n 1 | sed "s/^[ \t]*//")
        HEALTH=$(yt clickhouse ctl status --address $YT_CONTROLLER --cluster-name $CLUSTER_NAME clickbench | grep "health" | head -n 1 | sed "s/^[ \t]*//")

        if [[ "$STATE" == "\"state\" = \"active\";" && "$HEALTH" == "\"health\" = \"good\";" && "$TOTAL_JOBS" -eq "$RUNNING_JOBS" ]]; then
                return 0
        else
                return 1

        fi
}

change_clique_size() {
        echo "Changing size. Instance count $1, vCPU $2, RAM $3 "
        yt clickhouse ctl set-speclet --address $YT_CONTROLLER --cluster-name $CLUSTER_NAME --alias clickbench "{"active" = %true;"enable_geodata" = %false;"family" = "chyt";"instance_count" = $1;"instance_cpu" = $2;"instance_total_memory" = $3;"pool" = "research";"restart_on_speclet_change" = %true;"stage" = "production";}"
}


run() {
        TRIES=3
        QUERY_NUM=1
        TOTAL_LINES=$(wc -l < queries.sql)
        cat queries.sql | while read query; do
                echo -n "["
                for i in $(seq 1 $TRIES); do
                        RES=$(yt clickhouse execute "$query" --alias *clickbench@0 --proxy $YT_PROXY --format JSON |  jq .statistics.elapsed 2>&1)
                        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
                        [[ "$i" != $TRIES ]] && echo -n ", "
                done
                if [[ $QUERY_NUM == $TOTAL_LINES ]]
                        then echo "]"
                else
                        echo "],"
                fi
                QUERY_NUM=$((QUERY_NUM + 1))
        done

}

clique_waiting() {
        while true; do
                if check_ready; then
                        echo "Clique is almost ready. Waiting 1 minute to stabilize"
                        sleep 60
                        break
                else
                        echo "Clique not ready. Waiting for 10 seconds"
                        sleep 10
             fi
        done
}

echo "-------------------------------------"
echo "Stopping public clique"
stop_public_clique

create_clique

change_clique_size 1 $CPU_HIGH $RAM_HIGH

clique_waiting
echo "-------------------------------------"
echo -n "Load time: "
command time -f '%e' fill_data
echo "-------------------------------------"

for i in "1 $CPU_HIGH $RAM_HIGH 48GB" "2 $CPU_HIGH $RAM_HIGH 96GB" "4 $CPU_HIGH $RAM_HIGH 192GB" "9 $CPU_LOW $RAM_LOW 360GB"
do
	set -- $i
	echo "Running test for $4 clique"
	change_clique_size $1 $2 $3
	clique_waiting
	run
done
