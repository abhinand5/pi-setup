// @file: path-guard-core.mjs
// @description: Решение «пропустить / заблокировать» для пути из write/edit — без Pi API.
// @dependencies: node:fs, node:path, node:os
// @created: 2026-11-18
//
// Вынесено из path-guard.ts, чтобы правила проверялись тестом без запуска сессии Pi: расширение
// импортирует эти функции, `node --test tests/path-guard.test.mjs` проверяет их напрямую.
//
// Правила (повод — #15723 п.5: `write` с `path="/home/denis/work 2>/dev/null"` создал каталог
// `/home/denis/work 2>` в домашнем каталоге, и нашёлся он двадцать вызовов спустя):
//
// 1. Символы шелла в пути — блок: инструмент пишет файл, а не исполняет строку; `>`, `|`, `;`
//    в пути означают, что автор аргумента собирал его как команду.
// 2. Абсолютный путь вне cwd, $HOME и /tmp — блок: запись мимо рабочего дерева почти всегда
//    следствие ошибки в аргументе, а не намерения.
// 3. Хвостовой пробел, перевод строки, NUL — блок: их не видно в выводе, и каталог получается
//    с невидимым именем.
// 4. Первый новый уровень пути — «двойник» существующего соседа по гомоглифам: `/home/denis/п/…`
//    при существующем `/home/denis/p` (#15743 п.1). Тот вызов создал четыре уровня каталогов в
//    домашнем каталоге, и нашлись они тремя вызовами позже.
// 6. Списки запрещённых слов `ru-spellcheck` (`ru-spellcheck/deny.txt`, `.ru-spellcheck-deny`) —
//    владение человека: агент, который может править deny-список, узаконивает собственную лексику
//    и делает проверку бессмысленной. Обход — PI_PATH_GUARD_ALLOW_DENY_LIST=1.
// 5. Запись в основное дерево, когда сессия работает в `.claude/worktrees/<имя>` (#15742 п.5):
//    правка уезжает не в дерево задачи, а prek-хук `root-files-clean` ловит такое только на
//    коммите — которого в основном дереве не будет.
//
// Легальная запись мимо этих мест — через `bash` (там шелл уместен) или явной просьбой к человеку.
// Осознанные обходы — переменные окружения PI_PATH_GUARD_ALLOW_TWIN и PI_PATH_GUARD_ALLOW_MAIN_TREE.
//
// Границы правил 4 и 5 названы честно:
// - проверка 4 сознательно узкая — только смена алфавита (кириллица ↔ латиница). Регистр (`P` рядом с
//   `p`) двойником не считается: на Linux это законно разные каталоги, и блокировать его — ложное
//   срабатывание на каждой машине с регистрозависимой ФС;
// - проверка 5 строковая и знает две раскладки: `<repo>/.claude/worktrees/<имя>` (msb-lk) и
//   `<repo>-wt/<задача>` (pi-setup). Любая другая раскладка воркдеревьев ею не покрыта. Запись в `vendor`
//   и `.env` воркдерева она не блокирует: это симлинки на основное дерево по замыслу.

import { existsSync, readdirSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { isAbsolute, join, resolve, sep } from "node:path";

/**
 * Пары «кириллица → похожие латинские»: по ним новый уровень пути отличается от того, что автор имел
 * в виду (`п` похожа и на `p`, и на `n`). Многосимвольных замен нет намеренно — сравнение посимвольное.
 */
const LOOKALIKES = {
	а: "a",
	б: "b",
	в: "b",
	г: "r",
	д: "d",
	е: "e",
	ж: "j",
	з: "3",
	и: "u",
	й: "u",
	к: "k",
	л: "l",
	м: "m",
	н: "hn",
	о: "o",
	п: "np",
	р: "p",
	с: "c",
	т: "t",
	у: "y",
	ф: "f",
	х: "x",
	ц: "c",
	ч: "4",
	ш: "w",
	щ: "w",
	ъ: "b",
	ь: "b",
	э: "e",
	ю: "u",
	я: "r",
};

/** Имя с кириллицей: без неё гомоглифа нет — подмена возможна только между двумя алфавитами. */
function hasCyrillic(name) {
	return /[\u0400-\u04ff]/.test(name);
}

/**
 * Имена отличаются только гомоглифами: посимвольно равны либо кириллический символ похож на латинский
 * (`п` ≈ `p`/`n`, `с` ≈ `c`). Одинаковые имена и разная длина — не двойники.
 */
function isConfusableName(left, right) {
	const a = left.toLowerCase();
	const b = right.toLowerCase();
	if (a === b || a.length !== b.length) return false;
	if (!hasCyrillic(a) && !hasCyrillic(b)) return false;
	for (let index = 0; index < a.length; index += 1) {
		if (a[index] === b[index]) continue;
		const leftLookalikes = LOOKALIKES[a[index]] ?? "";
		const rightLookalikes = LOOKALIKES[b[index]] ?? "";
		if (!leftLookalikes.includes(b[index]) && !rightLookalikes.includes(a[index])) return false;
	}
	return true;
}

/**
 * Первый несуществующий уровень пути и его сосед-двойник (#15743 п.1). Смотрим только первый новый
 * уровень: остальные тоже новые, и соседей у них ещё нет.
 *
 * @returns {{ dir: string, name: string, twin: string } | null}
 */
function findConfusableTwin(absolutePath, readdir, exists) {
	const parts = absolutePath.split(sep).filter((part) => part !== "");
	let current = sep;
	for (const part of parts) {
		if (exists(join(current, part))) {
			current = join(current, part);
			continue;
		}
		let entries = [];
		try {
			entries = readdir(current);
		} catch {
			return null;
		}
		const twin = entries.find((entry) => isConfusableName(entry, part));
		return twin ? { dir: current, name: part, twin } : null;
	}
	return null;
}

/**
 * Запись в основное дерево при активном воркдереве (#15742 п.5): сессия живёт в
 * `<repo>/.claude/worktrees/<имя>`, а путь целится в `<репо>` мимо этого каталога.
 */
function mainTreeViolation(absolutePath, cwd) {
	// Не до конца строки: сессия может стоять в подкаталоге воркдерева (`ctx.cwd` — текущий каталог),
	// и с якорем `$` правило молча выключалось бы ровно там (`…/worktrees/<имя>/extensions`).
	const resolved = resolve(cwd);
	const nested = resolved.match(/^(.*)[/\\]\.claude[/\\]worktrees[/\\]([^/\\]+)/);
	let repoRoot = null;
	let worktree = null;
	if (nested) {
		// Раскладка msb-lk: <repo>/.claude/worktrees/<имя>. Пустой корень (`/.claude/worktrees/x`)
		// дал бы `isUnder(path, "")` = истину для любого пути, то есть блокировку всего подряд.
		if (nested[1]) {
			repoRoot = nested[1];
			worktree = join(repoRoot, ".claude", "worktrees", nested[2]);
		}
	} else {
		// Родная раскладка pi-setup: <repo>-wt/<задача> (config/AGENTS.md: git worktree add ../pi-setup-wt/…).
		// Без неё правило не работало бы в самом репозитории, который везёт сторожа.
		const sibling = resolved.match(/^(.*)[/\\]([^/\\]+)-wt[/\\]([^/\\]+)/);
		if (sibling && sibling[1]) {
			repoRoot = join(sibling[1], sibling[2]);
			worktree = join(sibling[1], `${sibling[2]}-wt`, sibling[3]);
		}
	}
	if (!repoRoot) return null;
	if (!isUnder(absolutePath, repoRoot)) return null;
	if (isUnder(absolutePath, worktree)) return null;
	return { repoRoot, worktree };
}

/**
 * Списки запрещённых слов ru-spellcheck: и машинный (`~/.config/ru-spellcheck/deny.txt`), и проектный
 * (`.ru-spellcheck-deny`). Правка запрещена всегда — файл описывает политику языка, а не код.
 */
const DENY_LIST_PATH = /(^|[/\\])ru-spellcheck[/\\]deny\.txt$|(^|[/\\])\.ru-spellcheck-deny$/i;

/** Символы, которых не бывает в имени файла и которые означают «это собирали как команду». */
const SHELL_METACHARACTERS = /[<>|;&`$*?{}[\]()!^]/;

/** Управляющие символы: перевод строки, NUL, табуляция. */
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;

/** Пути, запись в которые считается «рядом с работой»: cwd, домашний каталог, временный. */
function allowedRoots(cwd) {
	const roots = [resolve(cwd)];
	const home = homedir();
	if (home) roots.push(resolve(home));
	const tmp = tmpdir();
	if (tmp) roots.push(resolve(tmp));
	// macOS: /tmp — симлинк на /private/tmp; сравнение по префиксу иначе не срабатывает.
	if (tmp && tmp.startsWith("/private/")) roots.push(resolve(tmp.slice("/private".length)));
	if (tmp && !tmp.startsWith("/private/")) roots.push(resolve("/private" + tmp));
	return roots;
}

function isUnder(path, root) {
	return path === root || path.startsWith(root.endsWith(sep) ? root : root + sep);
}

/**
 * Проверка пути инструмента write/edit.
 *
 * @param {string} path аргумент `path` как его прислала модель
 * @param {string} cwd текущий рабочий каталог сессии
 * @param {{ home?: string, tmp?: string }} [env] подмена корней для тестов
 * @returns {{ allowed: boolean, reason?: string, absolutePath?: string }}
 */
export function checkPath(path, cwd, env = {}) {
	if (typeof path !== "string" || path.trim() === "") {
		return { allowed: false, reason: "путь пустой: инструмент write/edit требует непустой path" };
	}

	if (CONTROL_CHARACTERS.test(path)) {
		return {
			allowed: false,
			reason:
				"путь содержит управляющий символ (перевод строки, NUL или табуляцию): такой каталог создастся с невидимым именем",
		};
	}

	const metacharacter = path.match(SHELL_METACHARACTERS);
	if (metacharacter) {
		return {
			allowed: false,
			reason:
				`путь содержит шелл-символ \`${metacharacter[0]}\` — его в имени файла не бывает. ` +
				"Похоже, аргумент собирали как команду (`/path 2>/dev/null`): инструмент пишет файл, а не исполняет строку. " +
				"Передайте голый путь; если нужен шелл — используйте bash",
		};
	}

	if (path !== path.trimEnd()) {
		return {
			allowed: false,
			reason: "путь кончается пробелом или переводом строки — в имени каталога это невидимый хвост",
		};
	}

	const absolutePath = isAbsolute(path) ? resolve(path) : resolve(cwd, path);

	if (isAbsolute(path)) {
		const roots = env.roots ?? allowedRoots(cwd);
		if (!roots.some((root) => isUnder(absolutePath, root))) {
			return {
				allowed: false,
				absolutePath,
				reason:
					`абсолютный путь ${absolutePath} вне рабочего каталога, домашнего каталога и /tmp. ` +
					"Запись мимо рабочего дерева — обычно следствие ошибки в аргументе, а не намерения: " +
					"проверьте путь, а для системного файла используйте bash",
			};
		}
	}

	if (!env.allowMainTree) {
		const mainTree = mainTreeViolation(absolutePath, cwd);
		if (mainTree) {
			return {
				allowed: false,
				absolutePath,
				reason:
					`путь ${absolutePath} — в основном дереве ${mainTree.repoRoot}, а сессия работает в воркдереве ${mainTree.worktree}. ` +
					"Правка уедет не в дерево задачи, а в основной чекаут, где её никто не закоммитит " +
					"(хук root-files-clean ловит такое только на коммите). Возьмите путь дерева задачи. " +
					"Осознанный обход — PI_PATH_GUARD_ALLOW_MAIN_TREE=1",
			};
		}
	}

	if (!env.allowDenyList && DENY_LIST_PATH.test(absolutePath)) {
		return {
			allowed: false,
			absolutePath,
			reason:
				`путь ${absolutePath} — список запрещённых слов ru-spellcheck. Он принадлежит человеку: ` +
				"агент, который может его править, узаконивает собственную лексику, и проверка перестаёт " +
				"что-либо значить. Правьте текст, а не список; осознанный обход (владелец машины) — " +
				"PI_PATH_GUARD_ALLOW_DENY_LIST=1",
		};
	}

	if (!env.allowTwin) {
		const twin = findConfusableTwin(
			absolutePath,
			env.readdir ?? readdirSync,
			env.exists ?? existsSync,
		);
		if (twin) {
			return {
				allowed: false,
				absolutePath,
				reason:
					`рядом уже есть ${join(twin.dir, twin.twin)} — имя «${twin.name}» отличается от него только гомоглифами ` +
					"(кириллица вместо латиницы или наоборот). Похоже на опечатку в пути: инструмент создал бы " +
					"рядом второй каталог. Проверьте путь; осознанный обход — PI_PATH_GUARD_ALLOW_TWIN=1",
			};
		}
	}

	return { allowed: true, absolutePath };
}

/**
 * Ответ Pi для заблокированного вызова.
 *
 * @param {{ allowed: boolean, reason?: string }} verdict
 * @returns {{ block: true, reason: string } | undefined}
 */
export function toToolCallResult(verdict) {
	if (verdict.allowed) return undefined;
	return { block: true, reason: `path-guard заблокировал запись.\n${verdict.reason}` };
}
