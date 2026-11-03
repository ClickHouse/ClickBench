# Sourced by the other scripts: the major version of the installed server
# (the install script picks the latest one from the PGDG repository).
PGVERSION=$(ls /usr/lib/postgresql 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -n1)
if [ -z "${PGVERSION}" ]; then
    echo "PostgreSQL is not installed" >&2
    exit 1
fi
