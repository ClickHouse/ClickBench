#!/bin/bash -x

# Launch a fresh VM that benchmarks ONE ClickHouse version unattended and sends
# the result to the sink (see cloud-init.sh.in), then self-terminates.
#
#   ./run-benchmark.sh <version>
#   machine=c6a.metal datasets="hits ssb mgbench" ./run-benchmark.sh 1.1.54378
#
# version is resolved against list-versions.sh to find its image; for versions
# built from source (clickhouse-built:<v>) the git tag and required GCC are read
# from build-from-source/versions.txt and the VM builds the image itself.

set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"

VERSION="${1:?usage: run-benchmark.sh <version>}"
machine="${machine:=c7a.4xlarge}"
repo="${repo:=ClickHouse/ClickBench}"
branch="${branch:=main}"
datasets="${datasets:=hits ssb mgbench tpch tpcds coffeeshop ontime uk job taxi}"   # each loads into its own database
tries="${tries:=6}"   # 1 cold + 5 hot runs
timeout="${timeout:-18000}"                 # load + (optional source build) + queries
volume="${volume:-1000}"                    # GB; headroom for loading all datasets in parallel (peak usage is higher than the on-disk total)
# gp3 root volume with provisioned throughput/IOPS (cold-cache query reads and
# the ingest are disk-bound). gp3 maxes at 1000 MB/s / 16000 IOPS per volume;
# the instance's own EBS bandwidth is the real ceiling.
iops="${iops:-16000}"
throughput="${throughput:-1000}"            # MB/s

# Transient AWS errors that clear on their own: spare capacity frees as instances
# drain, service quotas (vCPU/instance count, and the aggregate EBS storage quota that
# raises VolumeLimitExceeded) free as other benchmarks finish and their volumes are
# deleted, and API throttling (RequestLimitExceeded / Throttling) clears within
# seconds. A version sweep fires
# dozens of launches back-to-back and hits throttling far more than the single-shot
# main launcher, so we retry those too. aws_retry also guards the pre-launch
# describe-* calls — a throttled describe would blank arch/ami and make the launch
# fail with a non-retryable error, silently skipping that version. Genuine config
# errors (bad AMI, missing IAM perms, malformed user-data) don't match and fail
# fast, so a broken invocation never loops forever.
RETRY_RE='InsufficientInstanceCapacity|VcpuLimitExceeded|InstanceLimitExceeded|MaxSpotInstanceCountExceeded|RequestLimitExceeded|Throttling|VolumeLimitExceeded'
aws_retry() {
    local out rc
    while :; do
        out=$(AWS_PAGER='' "$@" 2>&1) && rc=0 || rc=$?
        if [ "${rc}" -eq 0 ]; then printf '%s\n' "${out}"; return 0; fi
        if printf '%s' "${out}" | grep -qE "${RETRY_RE}"; then
            printf 'aws: %s, retrying in 60s...\n' "$(printf '%s' "${out}" | grep -oE "${RETRY_RE}" | head -n1)" >&2
            sleep 60; continue
        fi
        printf '%s\n' "${out}" >&2; return "${rc}"   # different error — don't loop
    done
}

# Resolve the version against list-versions.sh: accept an exact version
# (26.6.1.1193, 1.1.54378, 53973) or a prefix at a dot boundary, choosing the
# latest match by version sort (26.6 -> 26.6.1.1193, 24 -> 24.12.x, 1.1 -> the
# newest 1.1.x).
LV="$(./list-versions.sh)"
line="$(awk -F'\t' -v v="${VERSION}" '$1==v' <<<"${LV}")"
if [ -z "${line}" ]; then
    line="$(awk -F'\t' -v v="${VERSION}" 'index($1, v".")==1' <<<"${LV}" | sort -V | tail -1)"
fi
[ -z "${line}" ] && { echo "unknown version: ${VERSION}" >&2; exit 1; }
VERSION="$(cut -f1 <<<"${line}")"   # canonicalise to the full version
image="$(cut -f2 <<<"${line}")"
[ "${image}" = "unavailable" ] && { echo "${VERSION} is unavailable (no image/package/source)" >&2; exit 1; }
echo "resolved to ${VERSION} (${image})"

# Prehistoric (date-labeled) and pre-Docker (revision < 53991) versions can't run the
# big/complex datasets (the large joins job/tpcds/tpch, the 600M-row SSB lineorder_flat and
# the 500M-row coffeeshop fact) -- loading them only wastes time or crashes. Drop them from
# the dataset list so the VM neither downloads nor loads them (run-version.sh applies the
# same skip as a safety net). numkey: bare N -> N; 1.1.N -> N; calver (major>=18) -> huge.
if [[ "${VERSION}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
   || [ "$(awk -v v="${VERSION}" 'BEGIN{n=split(v,a,"."); print (n==1? a[1] : (a[1]==1? a[3] : 1000000))}')" -lt 53991 ] 2>/dev/null; then
    datasets="$(printf '%s' "${datasets}" | tr ' ' '\n' | grep -vxE 'ssb|tpch|tpcds|coffeeshop|job' | tr '\n' ' ' | xargs)"
    echo "pre-Docker/prehistoric ${VERSION}: datasets reduced to [${datasets}]" >&2
fi

# For source-built versions, get the tag and required GCC from versions.txt (the tagged /
# bare-number builds). The prehistoric monthly reconstructions live in monthly.tsv instead
# and are rebuilt from their commit + revision by run-version.sh's ensure_built_image on the
# VM (tag/gcc are unused for them), so accept those too -- only a version in neither file is
# a genuine error.
tag="-"; gcc="5"
if [[ "${image}" == clickhouse-built:* ]]; then
    # Look the recipe up via command substitution, not `read < <(...)`: with `set -e`, read
    # hitting EOF (version absent from versions.txt, e.g. a monthly build) returns non-zero
    # and would abort the script before the monthly.tsv fallback below.
    recipe="$(awk -F'\t' -v v="${VERSION}" '$1==v{print $2, ($4==""?5:$4)}' build-from-source/versions.txt)"
    if [ -n "${recipe}" ]; then
        read -r tag gcc <<<"${recipe}"
    elif awk -F'\t' -v v="${VERSION}" '$1==v{f=1} END{exit !f}' build-from-source/monthly.tsv; then
        tag="-"; gcc="5"   # monthly reconstruction: run-version.sh rebuilds it from monthly.tsv
    else
        echo "no build recipe for ${VERSION} in versions.txt or monthly.tsv" >&2; exit 1
    fi
fi

arch=$(aws_retry aws ec2 describe-instance-types --instance-types "$machine" --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text)
ami=$(aws_retry aws ec2 describe-images --owners amazon --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04*" "Name=architecture,Values=${arch}" "Name=state,Values=available" --query 'sort_by(Images, &CreationDate) | [-1].[ImageId]' --output text)

awk -v repo="$repo" -v branch="$branch" -v version="$VERSION" -v image="$image" \
    -v tag="$tag" -v gcc="$gcc" -v datasets="$datasets" -v tries="$tries" -v t="$timeout" '
{
    gsub(/@repo@/, repo); gsub(/@branch@/, branch); gsub(/@version@/, version)
    gsub(/@image@/, image); gsub(/@tag@/, tag); gsub(/@gcc@/, gcc)
    gsub(/@datasets@/, datasets); gsub(/@tries@/, tries); gsub(/@timeout@/, t)
    print
}' cloud-init.sh.in > "cloud-init.${VERSION}.sh"

# Launch the VM, backing off on transient capacity / quota / throttling errors.
aws_retry aws ec2 run-instances --image-id "$ami" --instance-type "$machine" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true,VolumeSize=${volume},VolumeType=gp3,Iops=${iops},Throughput=${throughput}}" \
    --instance-initiated-shutdown-behavior terminate \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=clickbench-versions-${VERSION}}]" \
    --user-data "file://cloud-init.${VERSION}.sh"
