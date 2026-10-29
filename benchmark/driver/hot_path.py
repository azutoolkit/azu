#!/usr/bin/env python3
"""Paired loopback smoke benchmark; not a TechEmpower or open-loop latency test.

Usage: python3 benchmark/driver/hot_path.py bin/http-before bin/http-after output.json
Requires Python 3 and wrk in PATH. Both servers use PORT and CRYSTAL_WORKERS.
"""

import http.client
import json
import os
import re
import statistics
import subprocess
import sys
import time


def latency_us(value):
    number, unit = re.fullmatch(r"([0-9.]+)(us|ms|s)", value).groups()
    return float(number) * {"us": 1, "ms": 1000, "s": 1000000}[unit]


def run(binary, workers, route):
    port = int(os.environ.get("PORT", "3099"))
    env = dict(os.environ, PORT=str(port), CRYSTAL_WORKERS=str(workers))
    process = subprocess.Popen([os.path.abspath(binary)], env=env, stdout=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if process.poll() is not None:
                raise RuntimeError(f"{binary} exited before readiness")
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            try:
                connection.request("GET", route)
                response = connection.getresponse()
                expected = b"Hello, World!" if route == "/plaintext" else b'{"message":"Hello, World!"}'
                assert response.status == 200 and response.read() == expected
                assert response.getheader("X-Request-ID")
                assert response.getheader("X-Content-Type-Options") == "nosniff"
                assert response.getheader("Content-Length") == str(len(expected))
                assert response.getheader("Transfer-Encoding") is None
                break
            except (ConnectionError, OSError):
                time.sleep(0.05)
            finally:
                connection.close()
        else:
            raise RuntimeError("server readiness timeout")
        command = ["wrk", "-t2", "-c64", "--latency", f"http://127.0.0.1:{port}{route}"]
        subprocess.run(command + ["-d1s"], check=True, capture_output=True, timeout=10)
        output = subprocess.check_output(command + ["-d4s"], text=True, timeout=15)
        if "Socket errors:" in output or "Non-2xx or 3xx responses:" in output:
            raise RuntimeError(output)
        percentiles = re.findall(r"\s+(50|90|99)%\s+(\S+)", output)
        return {
            "rps": float(re.search(r"Requests/sec:\s+([0-9.]+)", output)[1]),
            **{f"p{percentile}_us": latency_us(value) for percentile, value in percentiles},
            "wrk": output,
        }
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    before, after, destination = sys.argv[1:]
    samples = []
    for repetition in range(3):
        for workers in (1, 4, 16):
            for route in ("/plaintext", "/json"):
                versions = [("before", before), ("after", after)]
                if repetition % 2:
                    versions.reverse()
                for version, binary in versions:
                    sample = dict(version=version, workers=workers, route=route, repetition=repetition)
                    sample.update(run(binary, workers, route))
                    samples.append(sample)
                    with open(destination, "w") as output:
                        json.dump(samples, output, indent=2)
                    print({key: value for key, value in sample.items() if key != "wrk"}, flush=True)
    for workers in (1, 4, 16):
        for route in ("/plaintext", "/json"):
            for version in ("before", "after"):
                selected = [s for s in samples if (s["workers"], s["route"], s["version"]) == (workers, route, version)]
                print(workers, route, version, {key: statistics.median(s[key] for s in selected) for key in ("rps", "p50_us", "p99_us")})


if __name__ == "__main__":
    main()
