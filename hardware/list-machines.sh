#!/bin/bash -e

# Print the largest size of every current-generation EC2 instance family of a
# category offered in the region, one instance type per line:
#
#   ./list-machines.sh general-purpose     # m5.24xlarge m6g.16xlarge m7i.48xlarge ...
#   ./list-machines.sh compute-optimized   # c*
#   ./list-machines.sh memory-optimized    # r*
#   ./list-machines.sh storage-optimized   # i*
#
# The largest size is the one with the most vCPUs; between a virtualized size
# and a metal size with the same vCPUs (m7i.48xlarge and m7i.metal-48xl) the
# virtualized one is taken. Mac instances (mac1, mac2, ...) are left out: they
# run only on dedicated hosts.

case "${1:-general-purpose}" in
    general-purpose)   prefix=m ;;
    compute-optimized) prefix=c ;;
    memory-optimized)  prefix=r ;;
    storage-optimized) prefix=i ;;
    *) echo "usage: list-machines.sh general-purpose|compute-optimized|memory-optimized|storage-optimized" >&2; exit 1 ;;
esac

AWS_PAGER='' aws ec2 describe-instance-types \
    --filters "Name=instance-type,Values=${prefix}*" "Name=current-generation,Values=true" \
    --query 'InstanceTypes[].[InstanceType, VCpuInfo.DefaultVCpus, BareMetal]' \
    --output text |
awk -v prefix="${prefix}" '
{
    split($1, parts, ".")
    family = parts[1]
    if (family !~ "^" prefix "[0-9]") next     # mac2.metal, etc.
    metal = ($3 == "True")
    if (!(family in best) || $2 > vcpus[family] || ($2 == vcpus[family] && metals[family] && !metal)) {
        best[family] = $1; vcpus[family] = $2; metals[family] = metal
    }
}
END { for (f in best) print best[f] }' | sort -V
