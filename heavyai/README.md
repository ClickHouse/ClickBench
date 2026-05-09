# HeavyDB / Heavy.AI

## Dead (May 2026)

The benchmark installs HEAVY.AI from the project's apt repo:

    curl https://releases.heavy.ai/GPG-KEY-heavyai | apt-key add -
    echo "deb https://releases.heavy.ai/os/apt/ stable cpu" > /etc/apt/sources.list.d/heavyai.list
    apt-get install heavyai

Both URLs now return S3 `AccessDenied`:

    HTTP/2 403
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>AccessDenied</Code><Message>Access Denied</Message>...

There is no `heavyai/core-os-cpu` image on Docker Hub either. HEAVY.AI's public distribution channels are gone. The directory and historical results are kept; nothing here runs anymore.
