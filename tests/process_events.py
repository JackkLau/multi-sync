"""Bounded reads of line events without mixing OS readiness with TextIO buffering."""
import json
import queue
import threading


class ProcessEvents:
    def __init__(self, stream):
        self._lines = queue.Queue()
        self._ended = False
        self._reader = threading.Thread(target=self._read, args=(stream,), daemon=True)
        self._reader.start()

    def _read(self, stream):
        try:
            for line in stream:
                self._lines.put(line)
        finally:
            self._lines.put(None)

    def next(self, timeout=15):
        if self._ended:
            raise AssertionError("engine closed stdout without another event")
        try:
            line = self._lines.get(timeout=timeout)
        except queue.Empty:
            raise AssertionError("engine did not emit an event before timeout") from None
        if line is None:
            self._ended = True
            raise AssertionError("engine closed stdout without another event")
        return json.loads(line)

    def join(self):
        """Call after the producer exits and before closing its stdout pipe."""
        self._reader.join(timeout=2)
        if self._reader.is_alive():
            raise AssertionError("event reader did not stop after engine exit")
