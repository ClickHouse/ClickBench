#!/bin/bash
set -e

PARAMS_FILE="benchmark_variables.sh"
source $PARAMS_FILE
export YDB_PASSWORD=password
START_DIR=`pwd`

update_file() {
    local raw_input="$1"
    local raw_output="$2"
    local verbose="${3:-0}"

    expand_path() {
        local path="$1"
        path="${path/#\~/$HOME}"

        local expanded_path
        expanded_path=$(eval echo "$path")
        echo "$expanded_path"
    }

    local input_file
    local output_file
    input_file=$(expand_path "$raw_input")
    output_file=$(expand_path "$raw_output")

    local output_dir
    output_dir=$(dirname "$output_file")

    # Making temporary file
    local temp_file
    temp_file=$(mktemp) || {
        echo "Error while creating temporary file" >&2
        return 7
    }

    cleanup() {
        rm -f "$temp_file"
    }
    trap cleanup EXIT

    cp "$input_file" "$temp_file" || {
        echo "Error while copying input file to temporary file" >&2
        return 8
    }

    local env_vars
    env_vars=$(env | cut -d= -f1)

    for var in $env_vars; do
        local value
        value="${!var}"

        if grep -q "\$$var" "$temp_file"; then
            local escaped_value
            escaped_value=$(echo "$value" | sed -e 's/[\/&]/\\&/g')

            sed -i "s/\$$var/$escaped_value/g" "$temp_file" || {
                echo "Error while substituting variable \$$var." >&2
                return 9
            }
        fi
    done

    cp "$temp_file" "$output_file" || {
        return 10
    }

    return 0
}

sudo apt-get update -y
sudo apt-get install -y software-properties-common
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt-get install -y ansible-core

cd $START_DIR
if [ ! -d "ydb" ]; then
    git clone https://github.com/ydb-platform/ydb.git
fi

cd $START_DIR/ydb/ydb/apps/ydbd/
git checkout stable-25-1-analytics || { echo "Error while checking branch out"; exit 1; }
$START_DIR/ydb/ya make -j8 --build=release || { echo "Build error"; exit 1; }

cd $START_DIR/ydb/ydb/apps/ydb/
$START_DIR/ydb/ya make -j8 --build=release || { echo "Build error"; exit 1; }

cd $START_DIR/ydb/ydb/apps/dstool/
$START_DIR/ydb/ya make -j8 --build=release || { echo "Build error"; exit 1; }

cd $START_DIR
if [ ! -d "ydb-ansible-examples" ]; then
    git clone https://github.com/ydb-platform/ydb-ansible-examples.git
fi

cd $START_DIR/ydb-ansible-examples
ansible-galaxy install -r requirements.yaml
cd $START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc


rm -f $START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/ydbd
rm -f $START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/ydb
rm -f $START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/ydb-dstool

ln -f $START_DIR/ydb/ydb/apps/ydbd/ydbd $START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/
ln -f $START_DIR/ydb/ydb/apps/ydb/ydb $START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/
ln -f $START_DIR/ydb/ydb/apps/dstool/ydb-dstool $START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/

cd $START_DIR

update_file "ydb-cluster-setup/50-inventory.yaml" "$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/inventory/50-inventory.yaml"
update_file "ydb-cluster-setup/config.yaml" "$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/config.yaml"
update_file "ydb-cluster-setup/ydb-ca-nodes.txt" "$START_DIR/ydb-ansible-examples/TLS/ydb-ca-nodes.txt"

hosts=( "$host1$host_suffix" "$host2$host_suffix" "$host3$host_suffix" )
disks=( "$disk1" "$disk2" "$disk3" )

replace_string_in_file() {
    local file_path="$1"
    local search_string="$2"
    local replace_string="$3"
    local temp_file

    if [[ ! -f "$file_path" ]]; then
        echo "Error: File $file_path does not exist" >&2
        return 1
    fi

    temp_file=$(mktemp)

    sed "s|$search_string|$replace_string|g" "$file_path" > "$temp_file"

    if [ $? -ne 0 ]; then
        echo "Error: Replacement operation failed"
        rm -f "$temp_file"
        return 4
    fi

    mv "$temp_file" "$file_path"

    return 0
}

ssh_execute() {
    declare -n local_hosts="$1"
    local command="$2"

    for host in "${local_hosts[@]}"; do

        echo "Executing on $host: $command" >&2
        echo "$command" | ssh -l $ydb_host_user_name -o BatchMode=yes -o StrictHostKeyChecking=no "$host" "bash -s"
        local exit_code=$?

        if [ $exit_code -ne 0 ]; then
            echo "Command failed with exit code: $exit_code" >&2
        fi
    done

    return 0
}

copy_file_to_multiple_hosts() {
    local file_to_copy=$1
    shift

    local hosts=("$@")
    local pids=()

    for host in "${hosts[@]}"; do
        {
            echo "Copying file '$file_to_copy' to $host"
            scp "$file_to_copy" $ydb_host_user_name@$host:/home/$ydb_host_user_name
        } &
        pids+=($!)
    done

    # Waiting for all background processes to complete
    for pid in "${pids[@]}"; do
        wait $pid
    done

    echo "Сopy process is complete"
}

# Cleaning up YDB services on remote hosts
remove_ydb_services() {
    local host=$1

    # Connecting to server
    ssh -o StrictHostKeyChecking=no -l $ydb_host_user_name -o BatchMode=yes "$host"  '
        services=$(sudo systemctl list-units --type=service --all| grep "ydb" | awk "{print \$1}")

        if [ -z "$services" ]; then
            echo "YDB are not found"
        else
            for service in $services; do
                sudo systemctl stop "$service"
                sudo systemctl disable "$service"

                unit_path=$(systemctl show -p FragmentPath "$service" | cut -d= -f2)

                if [ -n "$unit_path" ] && [ -f "$unit_path" ]; then
                    sudo rm -f "$unit_path"

                    service_name=$(basename "$unit_path")
                    if [ -f "/etc/systemd/system/$service_name" ]; then
                        sudo rm -f "/etc/systemd/system/$service_name"
                    fi

                    if [ -L "/etc/systemd/system/multi-user.target.wants/$service_name" ]; then
                        sudo rm -f "/etc/systemd/system/multi-user.target.wants/$service_name"
                    fi
                fi
            done

            sudo systemctl daemon-reload
            sudo systemctl reset-failed
        fi
    '

    echo "All operation on $host are finished"
}

echo "Beginning the process of removing YDB services on all hosts..."

for host in "${hosts[@]}"; do
    remove_ydb_services "$host"
done

cd $START_DIR/ydb-ansible-examples/TLS
find . -maxdepth 1 -type d -not -path "." -exec rm -rf {} \;
if [ -f "$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/TLS" ]; then
    cd $START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/TLS
    rm -rf *
fi

cd $START_DIR/ydb-ansible-examples/TLS
./ydb-ca-update.sh
cd CA/certs
newest_dir=$(find . -maxdepth 1 -type d -not -path "." -printf "%T@ %p\n" | sort -n | tail -n 1 | cut -d' ' -f2-)

cd $START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/inventory/
replace_string_in_file "50-inventory.yaml" "<TLS_PATH>" "$START_DIR/ydb-ansible-examples/TLS/CA/certs/$newest_dir"
replace_string_in_file "50-inventory.yaml" "$ydb_host_user_name" "$ydb_host_user_name"

ssh_execute hosts "sudo mkdir -p /opt/ydb/bin && sudo chmod 755 /opt/ydb/bin"

cd $START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/
copy_file_to_multiple_hosts  "ydbd" $host1$host_suffix $host2$host_suffix $host3$host_suffix

obliterate_disks() {
    declare -n local_hostsd="$1"
    declare -n local_disks="$2"

    for disk in "${local_disks[@]}"; do
        ssh_execute local_hostsd "sudo /home/$ydb_host_user_name/ydbd admin blobstorage disk obliterate $disk"
    done
}

obliterate_disks hosts disks

ssh_execute hosts "rm -f /home/$ydb_host_user_name/ydbd"
ssh_execute hosts "sudo rm -rf /opt/ydb/"

cd $START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/
ansible-playbook ydb_platform.ydb.initial_setup --skip-tags checks

cd $START_DIR

if [ ! -f "hits.csv.gz" ]; then
    wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/hits.csv.gz
fi

if [ ! -f "hits.csv" ]; then
    echo "Unpacking hits.csv.gz"
    gzip -d -f -k hits.csv.gz
    echo "Done"
fi

# if [ -f "$HOME/.config/ydb/import_progress/hits.csv" ]; then
#     rm "$HOME/.config/ydb/import_progress/hits.csv"
# fi

cert_dir=$(find $START_DIR/ydb-ansible-examples/TLS/CA/certs -maxdepth 1 -type d -not -path "." -printf "%T@ %p\n" | sort -n | tail -n 1 | cut -d' ' -f2-)
echo $YDB_PASSWORD|$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/ydb -e grpcs://$host1$host_suffix:2135 -d /Root/database --ca-file $cert_dir/ca.crt --user root  workload clickbench init --datetime --store column
echo -n "Load time: "
command time -f '%e' echo $YDB_PASSWORD|$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/ydb -e grpcs://$host1$host_suffix:2135 -d /Root/database --ca-file $cert_dir/ca.crt --user root import file csv hits.csv -p clickbench/hits

cd $START_DIR
./run.sh
