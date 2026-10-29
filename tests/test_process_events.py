import subprocess
import sys
import unittest

from process_events import ProcessEvents


class ProcessEventsTests(unittest.TestCase):
    def test_batched_lines_do_not_wait_for_another_os_read(self):
        # Both events arrive in one write; the producer then waits for input.
        # select() + TextIO.readline() loses visibility of the second buffered line.
        code = 'import sys; sys.stdout.write(\'{"event":"first"}\\n{"event":"second"}\\n\'); sys.stdout.flush(); sys.stdin.read()'
        process = subprocess.Popen([sys.executable, "-u", "-c", code], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True, bufsize=1)
        events = ProcessEvents(process.stdout)
        try:
            self.assertEqual(events.next(timeout=5), {"event": "first"})
            self.assertEqual(events.next(timeout=1), {"event": "second"})
            with self.assertRaisesRegex(AssertionError, "before timeout"):
                events.next(timeout=0.05)
            process.stdin.close()
            self.assertEqual(process.wait(timeout=5), 0)
            with self.assertRaisesRegex(AssertionError, "closed stdout"):
                events.next(timeout=1)
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=5)
            events.join()
            process.stdin.close(); process.stdout.close()


if __name__ == "__main__":
    unittest.main()
