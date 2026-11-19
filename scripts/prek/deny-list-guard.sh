#!/usr/bin/env bash
# @file: deny-list-guard.sh
# @description: prek-хук: список запрещённых слов ru-spellcheck не меняется агентом молча (#15820).
# @dependencies: git, prek (хук запускает prek), bash
# @created: 2026-11-19
#
# Почему: `extensions/path-guard-core.mjs` сторожит только `write`/`edit` — команду `bash` он не видит,
# поэтому deny-список можно было переписать через `sed`/`cat >` в той же сессии, и сторож записи этого
# не замечал. Deny-список описывает лексику, которую агент не узаконивает; если он же может его править,
# проверка превращается в самообслуживание. Гейт стоит на коммите: файл уезжает в `main` и на другие
# машины только через коммит, а `install.sh` раскладывает его из репозитория.
#
# Хук не спорит с владельцем машины: осознанная правка проходит обходом
# `SKIP=deny-list-guard git commit …` (штатный обход prek), и тогда в сообщении коммита стоит сказать,
# почему слово добавлено или убрано.
#
# Запуск вручную: bash scripts/prek/deny-list-guard.sh config/ru-spellcheck/deny.txt
# Коды: 0 — deny-список не тронут (или обход включён); 1 — файл в индексе изменён.

set -uo pipefail

# Осознанный обход без SKIP: удобно, когда хук зовут вручную или обёрткой.
BYPASS_ENV="PI_ALLOW_DENY_LIST_CHANGE"
PROTECTED="config/ru-spellcheck/deny.txt"

if [[ "${!BYPASS_ENV:-}" == "1" ]]; then
    echo "deny-list-guard: ${BYPASS_ENV}=1 — правка ${PROTECTED} пропущена осознанно" >&2
    exit 0
fi

# Решает индекс, а не список аргументов: `prek run --all-files` передаёт путь и без правки, а хук
# должен молчать, пока файл не staged. Аргументы лишь сужают проверку (prek даёт только подходящие пути).
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if (($# > 0)); then
    matched=0
    for path in "$@"; do
        [[ "$path" == "$PROTECTED" ]] && matched=1
    done
    ((matched == 1)) || exit 0
fi

git -C "$repo_root" diff --cached --name-only --diff-filter=ACMR -- "$PROTECTED" | grep -qx "$PROTECTED" || exit 0

cat >&2 <<'EOF'
deny-list-guard: в индексе изменён config/ru-spellcheck/deny.txt.

Этот файл принадлежит человеку: он называет лексику, которую агент не должен узаконивать.
Агент, который может править deny-список, отменяет собственную проверку — именно так в allow
попадали «верные» ассерты, апрувы и резолвы (#15820).

Если правка осознанная и обоснована — повторите коммит с обходом и назовите причину в сообщении:

    SKIP=deny-list-guard git commit …

Осознанный обход без SKIP: PI_ALLOW_DENY_LIST_CHANGE=1 git commit …
EOF
exit 1
