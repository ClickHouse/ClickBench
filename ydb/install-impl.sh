#!/bin/bash
# YDB install: build binaries, provision the 3-node cluster, but do not load
# data or run queries (those are split into ./load and ./query).
set -e

PARAMS_FILE="benchmark_variables.sh"
source "$PARAMS_FILE"
export YDB_PASSWORD=password
START_DIR=$(pwd)

update_file() {
    local raw_input="$1"
    local raw_output="$2"

    expand_path() {
        local path="$1"
        path="${path/#\~/$HOME}"
        eval echo "$path"
    }

    local input_file output_file
    input_file=$(expand_path "$raw_input")
    output_file=$(expand_path "$raw_output")

    local temp_file
    temp_file=$(mktemp)
    trap 'rm -f "$temp_file"' EXIT

    cp "$input_file" "$temp_file"

    local env_vars
    env_vars=$(env | cut -d= -f1)
    for var in $env_vars; do
        local value="${!var}"
        if grep -q "\$$var" "$temp_file"; then
            local escaped_value
            escaped_value=$(echo "$value" | sed -e 's/[\/&]/\\&/g')
            sed -i "s/\$$var/$escaped_value/g" "$temp_file"
        fi
    done

    cp "$temp_file" "$output_file"
}

sudo apt-get update -y
sudo apt-get install -y software-properties-common
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt-get install -y ansible-core

cd "$START_DIR"
[ -d "ydb" ] || git clone https://github.com/ydb-platform/ydb.git

cd "$START_DIR/ydb/ydb/apps/ydbd/"
git checkout stable-25-1-analytics
"$START_DIR/ydb/ya" make -j8 --build=release

cd "$START_DIR/ydb/ydb/apps/ydb/"
"$START_DIR/ydb/ya" make -j8 --build=release

cd "$START_DIR/ydb/ydb/apps/dstool/"
"$START_DIR/ydb/ya" make -j8 --build=release

cd "$START_DIR"
[ -d "ydb-ansible-examples" ] || git clone https://github.com/ydb-platform/ydb-ansible-examples.git

cd "$START_DIR/ydb-ansible-examples"
ansible-galaxy install -r requirements.yaml

cd "$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc"
rm -f files/ydbd files/ydb files/ydb-dstool
ln -f "$START_DIR/ydb/ydb/apps/ydbd/ydbd" files/
ln -f "$START_DIR/ydb/ydb/apps/ydb/ydb" files/
ln -f "$START_DIR/ydb/ydb/apps/dstool/ydb-dstool" files/

cd "$START_DIR"
update_file "ydb-cluster-setup/50-inventory.yaml" "$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/inventory/50-inventory.yaml"
update_file "ydb-cluster-setup/config.yaml" "$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/config.yaml"
update_file "ydb-cluster-setup/ydb-ca-nodes.txt" "$START_DIR/ydb-ansible-examples/TLS/ydb-ca-nodes.txt"

hosts=( "$host1$host_suffix" "$host2$host_suffix" "$host3$host_suffix" )
disks=( "$disk1" "$disk2" "$disk3" )

ssh_execute() {
    declare -n local_hosts="$1"
    local command="$2"
    for host in "${local_hosts[@]}"; do
        echo "$command" | ssh -l "$ydb_host_user_name" -o BatchMode=yes -o StrictHostKeyChecking=no "$host" "bash -s" || true
    done
}

copy_file_to_multiple_hosts() {
    local file_to_copy=$1; shift
    local hosts=("$@")
    for host in "${hosts[@]}"; do
        scp "$file_to_copy" "$ydb_host_user_name@$host:/home/$ydb_host_user_name" &
    done
    wait
}

remove_ydb_services() {
    local host=$1
    ssh -o StrictHostKeyChecking=no -l "$ydb_host_user_name" -o BatchMode=yes "$host" '
        services=$(sudo systemctl list-units --type=service --all | grep "ydb" | awk "{print \$1}")
        if [ -n "$services" ]; then
            for service in $services; do
                sudo systemctl stop "$service" || true
                sudo systemctl disable "$service" || true
                unit_path=$(systemctl show -p FragmentPath "$service" | cut -d= -f2)
                if [ -n "$unit_path" ] && [ -f "$unit_path" ]; then
                    sudo rm -f "$unit_path"
                fi
            done
            sudo systemctl daemon-reload
            sudo systemctl reset-failed
        fi
    ' || true
}

for host in "${hosts[@]}"; do remove_ydb_services "$host"; done

cd "$START_DIR/ydb-ansible-examples/TLS"
find . -maxdepth 1 -type d -not -path "." -exec rm -rf {} \;
[ -d "$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/TLS" ] \
    && rm -rf "$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/TLS"/*

./ydb-ca-update.sh
cd CA/certs
newest_dir=$(find . -maxdepth 1 -type d -not -path "." -printf "%T@ %p\n" | sort -n | tail -n 1 | cut -d' ' -f2-)

cd "$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/inventory/"
sed -i "s|<TLS_PATH>|$START_DIR/ydb-ansible-examples/TLS/CA/certs/$newest_dir|g" 50-inventory.yaml

ssh_execute hosts "sudo mkdir -p /opt/ydb/bin && sudo chmod 755 /opt/ydb/bin"

cd "$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/files/"
copy_file_to_multiple_hosts "ydbd" "$host1$host_suffix" "$host2$host_suffix" "$host3$host_suffix"

for disk in "${disks[@]}"; do
    ssh_execute hosts "sudo /home/$ydb_host_user_name/ydbd admin blobstorage disk obliterate $disk"
done

ssh_execute hosts "rm -f /home/$ydb_host_user_name/ydbd"
ssh_execute hosts "sudo rm -rf /opt/ydb/"

cd "$START_DIR/ydb-ansible-examples/3-nodes-mirror-3-dc/"
ansible-playbook ydb_platform.ydb.initial_setup --skip-tags checks
