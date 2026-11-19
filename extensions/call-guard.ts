// @file: call-guard.ts
// @description: Блокирует bash-вызов без цели (`cd …; true`) и дамп списка веток/remote без фильтра.
// @dependencies: @earendil-works/pi-coding-agent, ./call-guard-core.mjs
// @created: 2026-11-19
//
// Зачем: #15738 п.5 (пять пустых вызовов и один дамп домашнего каталога) и #15749 п.5
// (`git branch -a` вернул 2168 строк, 50 КБ). Правило было записано в AGENTS.md, но гейта у него не было.
//
// Блокировка без диалога: пустой вызов и нефильтрованный список веток — это ошибка в аргументе,
// а не решение пользователя, и спрашивать «разрешить?» значит предлагать её подтвердить.
// Осознанный обход — PI_CALL_GUARD_ALLOW=1.
//
// Отключить на сессию: `pi --no-extensions` или убрать файл из `~/.pi/agent/extensions`.

import { isToolCallEventType, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { classifyCall, toToolCallResult } from "./call-guard-core.mjs";

export default function callGuard(pi: ExtensionAPI) {
	pi.on("tool_call", async (event) => {
		if (!isToolCallEventType("bash", event)) return undefined;

		const command = event.input.command;
		if (typeof command !== "string") return undefined;

		// Обход читается на момент вызова: его включают в окружении сессии, а не при загрузке pi.
		return toToolCallResult(classifyCall(command, { allow: process.env.PI_CALL_GUARD_ALLOW === "1" }));
	});
}
