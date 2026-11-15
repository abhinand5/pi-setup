---
name: release-please
description: >-
  Use before merging a PR, or when the repo has `.github/workflows/release-please.yml` /
  `release-please-config.json`; when choosing merge order; when waiting for the release PR
  `chore(main): release X.Y.Z`; when verifying the tag against `.release-please-manifest.json`;
  or when reporting merge results.
---

# Мерж и релиз в репозиториях с release-please

Пакеты с release-please, например `msb-calculator-api`. Где есть
`.github/workflows/release-please.yml` + `release-please-config.json`: **один мерж — один
релиз**. Пакетный мерж нескольких PR подряд складывает их в один релиз, и разделить потом
нельзя — release-please собирает релизный PR по всему, что накопилось на `main` с прошлого тега.

## Порядок

1. Смержить **один** PR (предпочтительно squash, как в репозитории). Из worktree — **без
   `--delete-branch`**: `gh pr merge <n> --squash --delete-branch` падает на `failed to run git:
   fatal: 'main' is already used by worktree` (переключение локального чекаута на базовую ветку
   упирается в другой worktree), хотя сам PR уже смержен — красный лог при зелёном результате.
   Ветку удалять отдельной командой, состояние смотреть по `state`/`mergedAt`/`mergedBy` (поля
   `merged` в `gh pr view --json` нет: `Unknown JSON field: merged`). #15611 п.6.

   ```bash
   gh pr merge <n> --squash
   git push origin --delete <branch>
   gh pr view <n> --json state,mergedAt,mergedBy
   ```
2. Дождаться релизного PR `chore(main): release X.Y.Z` — его открывает workflow на push в `main`
   (несколько секунд, смотреть `gh pr list --state open --search 'release'`). Пока он открыт,
   следующий PR не смержить: шаг `Release gate` в `ci.yml` красный и называет его номер.
3. Смержить релизный PR и проверить результат: `gh release list --limit 1` и
   `git show origin/main:.release-please-manifest.json` — версия должна совпасть с тегом `vX.Y.Z`.
4. Доложить строкой «смержено #N → релиз vX.Y.Z» и только потом браться за следующий PR.

## Когда релиза не будет

Бамп дают только типы из `changelog-sections` в `release-please-config.json` (`feat`, `fix`,
`refactor` в `msb-calculator-api`). `chore`/`docs`/`test` не бампают версию и в changelog не
попадают — после такого мержа релизного PR ждать не надо, версия поднимется следующим
бо-фиксным/фича-мержем. Так и писать в докладе: «смержено #N → релиза нет (docs)».

## Чего не делать

- Не мержить второй PR, пока не смержен релизный PR предыдущего — иначе два изменения уедут
  одним релизом.
- Не ставить теги и не создавать релизы руками: они разъедутся с `.release-please-manifest.json`
  и `composer.json` → `version`.
- Не править `version`/`CHANGELOG.md`/manifest вручную — это делает release-please.
