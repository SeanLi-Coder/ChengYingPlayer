#!/usr/bin/env python3
"""Small owned helper used to prove native graceful exit and restart ordering."""

import json
import sys
import time

print(json.dumps({"type": "ready", "protocol_version": 1}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    if request["command"] == "shutdown":
        time.sleep(0.2)
        break
    print(json.dumps({"type": "pong", "id": request["id"]}), flush=True)
