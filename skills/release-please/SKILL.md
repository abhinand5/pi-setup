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
   **У релизного PR пустой список проверок и статус «требуется действие» (`action_required`) —
   это норма, а не поломка:** workflow release-please открывает PR от токена, и проверки на его
   коммитах не запускаются. Сверять с прошлыми релизами не нужно, сливать как есть (#15647).

   **`Head branch is out of date` от `gh pr merge` — не отказ.** Сначала
   `gh pr view <n> --json state,mergedAt`: `state: OPEN` — повторить мерж, `MERGED` — мерж уже
   прошёл, и сообщение устарело, релиз выпущен (#15878 п.6).
4. Доложить строкой «смержено #N → релиз vX.Y.Z» и только потом браться за следующий PR.

## Когда релиза не будет

Версию поднимают только типы из `changelog-sections` в `release-please-config.json` (`feat`,
`fix`, `refactor` в `msb-calculator-api`). `chore`/`docs`/`test` версию не поднимают и в changelog
не попадают — после такого мержа релизного PR ждать не надо, версия вырастет при следующем
мерже типа `fix` или `feat`. Так и писать в докладе: «смержено #N → релиза нет (docs)».

## Релизный PR предлагает уже выпущенную версию

Симптом: в логе workflow release-please — `Duplicate release tag: v0.28.11` и `already_exists`,
при этом job зелёный. Версия не двигается: каждый следующий релизный PR снова предлагает 0.28.11,
а шаг `Release gate` в `ci.yml` показывает красным **все** обычные PR репозитория и сниматься не собирается.

Причина: на одну версию приходится два релизных PR, либо тег `vX.Y.Z` уже стоит, а
`.release-please-manifest.json` остался на прошлой версии. Release-please считает версию от
manifest, а не от тегов, поэтому выпущенный тег не «расходуется»: посчитанная версия просто
совпадает с ним, и создать её повторно нельзя.

Лечение — сначала закрыть застрявший релизный PR (он предлагает уже выпущенную версию и держит
`Release gate`), затем пустой коммит с явно следующей версией:

```bash
gh pr list --state open --head release-please--branches--main   # тот самый PR
gh release list --limit 1                                       # последний выпущенный тег
git commit --allow-empty -m "chore: release 0.28.12" -m "Release-As: 0.28.12"
git push
```

`Release-As` ставится только на **следующую** версию (`X.Y.(Z+1)` для исправления), а не на ту, что уже
выпущена: иначе release-please снова упрётся в существующий тег. После того как workflow отработал,
сверить четыре источника — `gh release list --limit 1`, `git show origin/main:.release-please-manifest.json`,
`git show origin/main:composer.json` (поле `version`) и тег `vX.Y.Z`: совпали все четыре — версия
выпущена.

## Чего не делать

- Не мержить второй PR, пока не смержен релизный PR предыдущего — иначе два изменения уедут
  одним релизом.
- Не ставить теги и не создавать релизы руками: они разъедутся с `.release-please-manifest.json`
  и `composer.json` → `version`.
- Не искать причину в `action_required` у релизного PR и не ждать зелёных проверок: их не будет
  (см. § Порядок, шаг 3). Красным должно быть только `Release gate` на *обычном* PR.
- Не править `version`/`CHANGELOG.md`/manifest вручную — это делает release-please.
- Не ставить `Release-As` поверх открытого релизного PR: релизный PR уже посчитал версию, и второй
  коммит с тем же номером даёт дубль блока версии в `CHANGELOG.md`. Сначала закрыть старый PR
  (см. § Релизный PR предлагает уже выпущенную версию).
