# AGENTS.md — pi-setup

Указатели, а не пересказ. Скрипты здесь длинные (`install.sh` и `sync.sh` — сотни строк каждый), и
«прочитать целиком» втрое дороже нужной секции: в сессии #15675 на две справки ушло 49 КБ вывода —
16 % всего вывода инструментов сессии (#15738 п.2). Порядок: этот файл → секция README → `rg -n` по
ключу. Точные числа строк здесь не держим: они дрейфуют от любой правки, и первая версия этого файла
назвала их неверно.

- `bin/*` попадает в `~/.local/bin` через `install_bin_helpers` (`install.sh`); состав и правила —
  README → «This installs helper commands only».
- `sync.sh` снимает живой `~/.pi/agent` в репозиторий и коммитит; `install.sh --restore` раскладывает
  репозиторий обратно. Что именно едет — README → «Sync live Pi tweaks back to GitHub».
- Доставка правки — PR в `main` (`main` защищён); ветка — от `origin/main`, иначе в PR уезжает чужой
  коммит (проверка `git merge-base --is-ancestor origin/main HEAD` есть в CI).
- Разбор скрипта — `rg -n '<ключ>' install.sh sync.sh`, а не `cat`: `grep -n 'install_bin_helpers' install.sh`
  отвечает на вопрос «как helper попадает в PATH» одной строкой.
- Прогоны: `node --test tests/*.test.mjs` (правила сторожей), `bash tests/ru-spellcheck-*.sh`
  (словарь, deny-список, длинный ввод), `bash tests/browser-uat-login-proxy.sh` (uat login).
  `tests/docker-e2e.sh` — полный install в контейнере, минуты, вне CI намеренно.
- Сторожа агента живут в `extensions/*-core.mjs` (правило) + `*.ts` (хук Pi); обход — переменной
  окружения `PI_*_ALLOW=1`. Подробности — шапка каждого файла.
- `patches/` — локальные правки upstream-пакетов, применяются `install.sh` (`apply_local_patches`);
  `pi update --extensions` их откатывает.
- PR и коммиты — от личной учётки (`denis-trofimov`), не от служебного ключа; см. `~/.pi/agent/AGENTS.md`.
