"""Background HITL approver for runtime-e2e tests.

Polls the HITL queue and approves/rejects the first pending request.

Usage: python3 hitl_approver.py [approve|reject]
"""

import os
import sys
import time

import requests

action = sys.argv[1] if len(sys.argv) > 1 else "approve"
endpoint = os.environ["AXONFLOW_ENDPOINT"]
auth = os.environ["AXONFLOW_AUTH"]

for _ in range(60):
    time.sleep(1)
    try:
        resp = requests.get(
            f"{endpoint}/api/v1/hitl/queue?status=pending&limit=10",
            headers={"Authorization": f"Basic {auth}"},
            timeout=5,
        )
        if resp.status_code == 200:
            data = resp.json()
            items = data.get("data", data.get("items", []))
            if isinstance(items, list):
                for item in items:
                    if item.get("status") == "pending":
                        req_id = item["request_id"]
                        requests.post(
                            f"{endpoint}/api/v1/hitl/queue/{req_id}/{action}",
                            headers={
                                "Authorization": f"Basic {auth}",
                                "Content-Type": "application/json",
                            },
                            json={
                                "reviewer_id": f"e2e-{action}r",
                                "comments": f"{action}d by e2e test",
                            },
                            timeout=5,
                        )
                        print(f"{action.capitalize()}d HITL request {req_id}")
                        sys.exit(0)
    except Exception:
        pass

print("WARNING: no pending HITL request found after 60s")
sys.exit(1)
