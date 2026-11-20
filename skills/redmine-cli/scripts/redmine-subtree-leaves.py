#!/usr/bin/env python3
"""Leaf issues of a Redmine issue subtree, filtered by assignee and status.

Usage:
    eval "$(grep -E '^export REDMINE_' "$HOME/.profile")"
    python3 docs/dev/scripts/redmine-subtree-leaves.py 11310 --users 127,147 --statuses 1,8

The subtree is walked with `parent_id` queries (one `redmine api` call per node that has children),
because `redmine issues list --parent` returns direct children only. Leaves are nodes without children,
checked over the whole subtree rather than one level.
"""
import argparse
import json
import os
import subprocess
import sys

# Redmine serves these names; sorting "priority decreasing" means this order.
PRIORITY_RANK = {
    "Немедленно(expedite)": 5,
    "Очень высокий(and fixed date)": 4,
    "Высокий": 3,
    "Нормальный": 2,
    "Минимальный": 1,
}


def api(path):
    result = subprocess.run(
        ["redmine", "api", path, "-o", "json"],
        capture_output=True,
        text=True,
        env=os.environ,
    )
    if result.returncode != 0:
        sys.exit(f"redmine api {path} failed: {result.stderr.strip()[:300]}")
    return json.loads(result.stdout)


def children(parent_id):
    """All children of one issue, paged. `status_id=*` keeps closed children in the subtree."""
    base = f"/issues.json?status_id=*&parent_id={parent_id}&limit=100"
    first = api(base)
    issues = list(first.get("issues", []))
    total = first.get("total_count", len(issues))
    page = 2
    while len(issues) < total and page <= 100:
        issues += api(f"{base}&page={page}").get("issues", [])
        page += 1
    return issues


def walk(root):
    nodes, tree, queue, seen = {}, {}, [root], {root}
    while queue:
        current = queue.pop(0)
        for issue in children(current):
            nodes[issue["id"]] = {
                "id": issue["id"],
                "subject": issue["subject"],
                "status": issue["status"]["name"],
                "status_id": issue["status"]["id"],
                "priority": issue["priority"]["name"],
                "tracker": issue["tracker"]["name"],
                "assignee": (issue.get("assigned_to") or {}).get("id"),
                "assignee_name": (issue.get("assigned_to") or {}).get("name") or "-",
            }
            tree.setdefault(current, []).append(issue["id"])
            if issue["id"] not in seen:
                seen.add(issue["id"])
                queue.append(issue["id"])
    return nodes, tree


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=int, help="subtree root issue id")
    parser.add_argument("--users", help="comma-separated assignee ids, e.g. 127,147")
    parser.add_argument("--statuses", help="comma-separated status ids, e.g. 1,8")
    args = parser.parse_args()

    users = {int(x) for x in args.users.split(",")} if args.users else None
    statuses = {int(x) for x in args.statuses.split(",")} if args.statuses else None

    nodes, tree = walk(args.root)
    leaves = [node for issue_id, node in nodes.items() if not tree.get(issue_id)]
    print(f"subtree of #{args.root}: {len(nodes)} issues, {len(leaves)} leaves", file=sys.stderr)

    selected = [
        node
        for node in leaves
        if (users is None or node["assignee"] in users)
        and (statuses is None or node["status_id"] in statuses)
    ]
    selected.sort(key=lambda node: (-PRIORITY_RANK.get(node["priority"], 0), node["id"]))

    print("id\tpriority\tstatus\tuser\ttracker\tsubject")
    for node in selected:
        print(
            f"{node['id']}\t{node['priority']}\t{node['status']}\t{node['assignee']}\t"
            f"{node['tracker']}\t{node['subject']}"
        )
    print(f"matched: {len(selected)}", file=sys.stderr)


if __name__ == "__main__":
    main()
