# HeavyDB / Heavy.AI

## Status (as of May 2026): unreproducible

The benchmark installs HEAVY.AI from the project's apt repo:

    curl https://releases.heavy.ai/GPG-KEY-heavyai | apt-key add -
    echo "deb https://releases.heavy.ai/os/apt/ stable cpu" > /etc/apt/sources.list.d/heavyai.list
    apt-get install heavyai

Both the GPG key URL and the apt repo are now behind an S3 `AccessDenied`:

    HTTP/2 403
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>AccessDenied</Code><Message>Access Denied</Message>...

`heavyai/core-os-cpu` is not on Docker Hub either. HEAVY.AI's public distribution channels appear to have gone away. The directory and historical results are kept for reference; new submissions aren't expected without a working install path.
