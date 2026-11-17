// @file: path-guard.ts
// @description: Блокирует write/edit с путём, содержащим шелл-символы или уводящим мимо рабочего дерева.
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

import { isToolCallEventType, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { checkPath, toToolCallResult } from "./path-guard-core.mjs";

export default function pathGuard(pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (isToolCallEventType("write", event)) {
			return toToolCallResult(checkPath(event.input.path, ctx.cwd));
		}

		if (isToolCallEventType("edit", event)) {
			return toToolCallResult(checkPath(event.input.path, ctx.cwd));
		}

		return undefined;
	});
}
