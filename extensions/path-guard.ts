// @file: path-guard.ts
// @description: Блокирует write/edit с путём, содержащим шелл-символы, уводящим мимо рабочего дерева,
//               указывающим на каталог-двойник по гомоглифу или в основное дерево при активном воркдереве.
// @dependencies: @earendil-works/pi-coding-agent, ./path-guard-core.mjs
// @created: 2026-11-18
//
// Зачем (#15723 п.5): `write` с `path="/home/denis/work 2>/dev/null"` создал каталог
// `/home/denis/work 2>` в домашнем каталоге. Каталог нашёлся при уборке воркдеревов примерно двадцать
// вызовов спустя — то есть потеря невидима, пока не посмотришь в `$HOME`. Шелл-метасимволы в пути
// означают, что аргумент собирали как команду; инструмент при этом пишет файл, а не исполняет строку.
//
// Правила и их обоснование — в path-guard-core.mjs (там же тесты, `node --test tests/path-guard.test.mjs`).
// Блокировка без диалога: путь с `>` или `|` — не решение пользователя, а ошибка в аргументе, и
// спрашивать «разрешить?» значит предлагать её подтвердить.
//
// Отключить на сессию: `pi --no-extensions` или убрать файл из `~/.pi/agent/extensions`.
// Осознанные обходы отдельных правил: PI_PATH_GUARD_ALLOW_TWIN=1 (каталог-двойник по гомоглифу),
// PI_PATH_GUARD_ALLOW_MAIN_TREE=1 (запись в основное дерево при активном воркдереве).

import { isToolCallEventType, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { checkPath, toToolCallResult } from "./path-guard-core.mjs";

/** Обходы читаются на момент вызова: их включают в окружении сессии, а не при загрузке pi. */
function verdict(path: string, cwd: string) {
	return toToolCallResult(
		checkPath(path, cwd, {
			allowTwin: process.env.PI_PATH_GUARD_ALLOW_TWIN === "1",
			allowMainTree: process.env.PI_PATH_GUARD_ALLOW_MAIN_TREE === "1",
		}),
	);
}

export default function pathGuard(pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (isToolCallEventType("write", event)) {
			return verdict(event.input.path, ctx.cwd);
		}

		if (isToolCallEventType("edit", event)) {
			return verdict(event.input.path, ctx.cwd);
		}

		return undefined;
	});
}
