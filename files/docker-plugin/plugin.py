#!/usr/bin/env python3
"""Кастомный плагин мониторинга (ЛР 4).

Собирает нестандартные метрики узла и отдаёт их в формате Prometheus
на :8888/metrics. Zabbix Agent 2 забирает их UserParameter'ом
custom.plugin.metrics (см. files/zabbix_agent2.conf), Splunk может
скрейпить тот же эндпоинт через Add-on for Prometheus.
"""
import os
import time
import platform
from http.server import BaseHTTPRequestHandler, HTTPServer

START = time.time()


def collect():
    now = time.time()
    with open("/proc/loadavg") as f:
        l1, l5, l15 = f.read().split()[:3]
    with open("/proc/meminfo") as f:
        mem = {k.split(":")[0]: int(v.split()[0]) for k, v in (line.split(":", 1) for line in f if ":" in line)}
    total = mem.get("MemTotal", 0)
    avail = mem.get("MemAvailable", 0)
    try:
        rx = sum(int(l.split()[1]) for l in open("/proc/net/dev").readlines()[2:] if ":" in l)
        tx = sum(int(l.split()[9]) for l in open("/proc/net/dev").readlines()[2:] if ":" in l)
    except Exception:
        rx = tx = 0
    lines = [
        "# HELP lab_uptime_seconds Process uptime",
        "# TYPE lab_uptime_seconds gauge",
        f"lab_uptime_seconds {now - START:.1f}",
        "# HELP lab_load1 1-minute load average",
        "# TYPE lab_load1 gauge",
        f"lab_load1 {l1}",
        f"lab_load5 {l5}",
        f"lab_load15 {l15}",
        "# HELP lab_memory_bytes Memory usage",
        "# TYPE lab_memory_bytes gauge",
        f"lab_memory_bytes{{kind='total'}} {total * 1024}",
        f"lab_memory_bytes{{kind='available'}} {avail * 1024}",
        "# HELP lab_net_bytes_total Interface byte counters (all ifaces)",
        "# TYPE lab_net_bytes_total counter",
        f"lab_net_bytes_total{{dir='rx'}} {rx}",
        f"lab_net_bytes_total{{dir='tx'}} {tx}",
        "# HELP lab_host_info Static host labels",
        "# TYPE lab_host_info gauge",
        f'lab_host_info{{hostname="{platform.node()}",os="{platform.system()}"}} 1',
    ]
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            body = collect().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PLUGIN_PORT", "8888"))
    print(f"[plugin] serving metrics on :{port}/metrics", flush=True)
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
