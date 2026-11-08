#!/usr/bin/env python3
"""
Live log: follow a log file and stream its lines to `sink.logs` on
play.clickhouse.com, where live.html shows them as they come with a streaming
query (`SELECT ... FROM sink.logs STREAM`).

Usage (see cloud-init.sh.in):

    LIVE_LOG_RUN_ID=<uuid> LIVE_LOG_SYSTEM=<system> LIVE_LOG_MACHINE=<machine> \
        live-log.py /var/log/cloud-init-output.log &
    ...
    kill -TERM $!; wait $!

The file is read from its beginning and followed like `tail -F` until SIGTERM
or SIGINT, after which the rest of the file is read, sent, and the program
exits, with a last empty row with `eof` = true. Lines are buffered and inserted at most once per LIVE_LOG_FLUSH_INTERVAL
seconds (default 1), as one INSERT per flush, numbered by `line_number` from 1.

It must never get in the way of the benchmark: it runs under `nice`, uses
only the standard library, and the failures of the inserts are reported into
the log itself (which then gets uploaded too) instead of stopping anything.
A failed batch is kept and retried with the next flush, with a growing pause;
if the backlog grows over MAX_PENDING_BYTES, it is discarded and replaced by
a line that tells how many lines were lost. The live log is a convenience:
the complete log is still sent to `sink.data` at the end of the run.
"""

import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request

URL = os.environ.get(
    'LIVE_LOG_URL',
    'https://play.clickhouse.com/?user=sink_logs&query=INSERT+INTO+logs+FORMAT+JSONEachRow')
RUN_ID = os.environ['LIVE_LOG_RUN_ID']
SYSTEM = os.environ.get('LIVE_LOG_SYSTEM', '')
MACHINE = os.environ.get('LIVE_LOG_MACHINE', '')
FLUSH_INTERVAL = float(os.environ.get('LIVE_LOG_FLUSH_INTERVAL', '1'))

POLL_INTERVAL = 0.1             # How often to look for new data in the file.
READ_SIZE = 1 << 20
MAX_LINE_BYTES = 16384          # Longer lines are cut, e.g. minified JSON or a progress bar.
MAX_BATCH_BYTES = 2_000_000     # Flush before the interval if this much is buffered.
MAX_PENDING_BYTES = 16_000_000  # Discard the backlog if inserts keep failing.
MAX_RETRY_PAUSE = 30
HTTP_TIMEOUT = 15

stopping = False


def on_signal(signum, frame):
    global stopping
    stopping = True


def report(message):
    # Goes to the log that we follow (stderr of the cloud-init script).
    print(f'live-log: {message}', file=sys.stderr, flush=True)


class Uploader:
    def __init__(self):
        self.line_number = 0
        self.pending = []           # Encoded JSONEachRow rows, not yet inserted.
        self.pending_bytes = 0
        self.failing = False
        self.retry_pause = FLUSH_INTERVAL
        self.next_flush = None      # Deadline of the next flush, None when there is nothing to send.

    def add(self, raw, eof=False):
        # A progress bar redraws its line with carriage returns: keep what a
        # terminal would show in the end, the last non-empty segment.
        if b'\r' in raw:
            segments = [s for s in raw.split(b'\r') if s]
            raw = segments[-1] if segments else b''
        if len(raw) > MAX_LINE_BYTES:
            raw = raw[:MAX_LINE_BYTES] + b'... [%d bytes cut]' % (len(raw) - MAX_LINE_BYTES)
        self.line_number += 1
        row = json.dumps({
            'run_id': RUN_ID,
            'system': SYSTEM,
            'machine': MACHINE,
            'line_number': self.line_number,
            'time': '%.3f' % time.time(),
            'line': raw.decode('utf-8', errors='replace'),
            'eof': eof,
        }, ensure_ascii=False).encode() + b'\n'
        self.pending.append(row)
        self.pending_bytes += len(row)
        if self.next_flush is None:
            self.next_flush = time.monotonic() + FLUSH_INTERVAL

    def due(self):
        return self.next_flush is not None and (
            time.monotonic() >= self.next_flush
            or (self.pending_bytes >= MAX_BATCH_BYTES and not self.failing))

    def flush(self):
        if not self.pending:
            self.next_flush = None
            return
        try:
            request = urllib.request.Request(URL, data=b''.join(self.pending), method='POST')
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
                response.read()
        except (urllib.error.URLError, OSError) as e:
            message = str(e)
            if isinstance(e, urllib.error.HTTPError):
                message += ': ' + e.read(1000).decode('utf-8', errors='replace').strip()
            if not self.failing:
                report(f'insert failed, will retry: {message}')
            self.failing = True
            if self.pending_bytes > MAX_PENDING_BYTES:
                lost = len(self.pending)
                report(f'discarding {lost} lines after failed inserts')
                self.pending.clear()
                self.pending_bytes = 0
                # Mark the gap for the reader. This row starts the new backlog.
                self.add(b'[live-log: %d lines were not uploaded]' % lost)
            self.retry_pause = min(self.retry_pause * 2, MAX_RETRY_PAUSE)
            self.next_flush = time.monotonic() + self.retry_pause
            return
        if self.failing:
            report('inserts work again')
        self.failing = False
        self.retry_pause = FLUSH_INTERVAL
        self.pending.clear()
        self.pending_bytes = 0
        self.next_flush = None


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: live-log.py <file>')
    path = sys.argv[1]
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    uploader = Uploader()
    f = None
    partial = b''
    while True:
        # Read what we can before checking the flag: after a stop request,
        # the rest of the file still has to be read and sent.
        finishing = stopping
        if f is None:
            try:
                f = open(path, 'rb')
            except FileNotFoundError:
                pass
        data = f.read(READ_SIZE) if f is not None else b''
        if data:
            *lines, partial = (partial + data).split(b'\n')
            for line in lines:
                uploader.add(line)
            # A line without the end, as long as the buffer: cut it here.
            if len(partial) > MAX_LINE_BYTES:
                uploader.add(partial)
                partial = b''
        if uploader.due():
            uploader.flush()
        if not data:
            if finishing:
                break
            time.sleep(POLL_INTERVAL)

    if partial:
        uploader.add(partial)
    # The end of the log: live.html stops following the run when it gets this row.
    uploader.add(b'', eof=True)
    # One last attempt, no retries: the machine is about to shut down.
    uploader.flush()


if __name__ == '__main__':
    main()
