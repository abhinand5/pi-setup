#!/usr/bin/env python3
"""Leaf issues of a Redmine issue subtree, filtered by assignee and status.

Usage:
    eval "$(grep -E '^export REDMINE_' "$HOME/.profile")"
    # все совпавшие листья (без окна)
    python3 .pi/skills/redmine-cli/scripts/redmine-subtree-leaves.py 11310 --users 127,147 --statuses 1,8
    # только тронутые с даты: фильтр по updated_on, а не по created_on
    python3 .pi/skills/redmine-cli/scripts/redmine-subtree-leaves.py 11310 --users 128 --statuses 9 --changed-since 2026-11-22

The subtree is walked with `parent_id` queries (one `redmine api` call per node that has children),
because `redmine issues list --parent` returns direct children only. Leaves are nodes without children,
checked over the whole subtree rather than one level.

`--changed-since` filters on `updated_on >= DATE`: «изменённые с прошлого воскресенья» — это свежая
запись журнала, а не дата создания. Дата без флага печатается колонкой `updated`, поэтому «пусто из-за
окна» отличается от «пусто из-за фильтра» без второго запроса к Redmine.

Строки выводятся готовой ссылкой `REDMINE_SERVER/issues/<id>`, а не голым номером: такую строку можно
вставить в заметку или в чат целиком. Первая колонка — порядковый номер пункта, последняя строка —
сколько пунктов напечатано.
"""

DEFAULT_SERVER = "https://redmine.msb-leasing.ru"


def plural(count, one, few, many):
    """Русская форма по числу: 1 пункт, 2 пункта, 5 пунктов."""
    if count % 10 == 1 and count % 100 != 11:
        return one
    if 2 <= count % 10 <= 4 and not 12 <= count % 100 <= 14:
        return few
    return many


def issue_url(server, issue_id):
    return f"{server.rstrip('/')}/issues/{issue_id}"
import argparse
import datetime
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
                "updated": (issue.get("updated_on") or "")[:10],
            }
            tree.setdefault(current, []).append(issue["id"])
            if issue["id"] not in seen:
                seen.add(issue["id"])
                queue.append(issue["id"])
    return nodes, tree


def iso_date(value):
    """YYYY-MM-DD; `updated_on` is compared as a string, so the shape has to be exact."""
    try:
        return datetime.date.fromisoformat(value).isoformat()
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected YYYY-MM-DD, got {value!r}")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("root", type=int, help="subtree root issue id")
    parser.add_argument(
        "--server",
        default=os.environ.get("REDMINE_SERVER") or DEFAULT_SERVER,
        help="Redmine base URL for issue links (default: $REDMINE_SERVER or %(default)s)",
    )
    parser.add_argument("--users", help="comma-separated assignee ids, e.g. 127,147")
    parser.add_argument("--statuses", help="comma-separated status ids, e.g. 1,8")
    parser.add_argument(
        "--changed-since",
        type=iso_date,
        metavar="YYYY-MM-DD",
        help="keep issues whose updated_on is on or after this date (last activity, not creation)",
    )
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
    window = ""
    if args.changed_since:
        before = len(selected)
        selected = [node for node in selected if node["updated"] >= args.changed_since]
        older = sum(1 for node in leaves if node["updated"] < args.changed_since)
        window = f" after changed-since {args.changed_since} ({before} → {len(selected)})"
        print(
            f"changed-since {args.changed_since}: subtree leaves older than that on updated_on — {older}",
            file=sys.stderr,
        )

    selected.sort(key=lambda node: (-PRIORITY_RANK.get(node["priority"], 0), node["id"]))

    print("#\turl\tpriority\tstatus\tupdated\tuser\ttracker\tsubject")
    for position, node in enumerate(selected, start=1):
        print(
            f"{position}\t{issue_url(args.server, node['id'])}\t{node['priority']}\t"
            f"{node['status']}\t{node['updated']}\t{node['assignee']}\t{node['tracker']}\t"
            f"{node['subject']}"
        )
    print(
        f"напечатано: {len(selected)} {plural(len(selected), 'пункт', 'пункта', 'пунктов')}"
    )
    print(f"matched: {len(selected)}{window}", file=sys.stderr)


if __name__ == "__main__":
    main()
