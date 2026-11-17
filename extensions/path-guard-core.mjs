// @file: path-guard-core.mjs
// @description: Решение «пропустить / заблокировать» для пути из write/edit — чистые функции без Pi API.
// @dependencies: node:path, node:os
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
//
// Легальная запись мимо этих мест — через `bash` (там шелл уместен) или явной просьбой к человеку.

import { homedir, tmpdir } from "node:os";
import { isAbsolute, resolve, sep } from "node:path";

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
