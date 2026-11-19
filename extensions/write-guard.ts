// @file: write-guard.ts
// @description: Блокирует `write`, который затирает отслеживаемый файл крупнее 1 КБ плейсхолдером.
// @dependencies: @earendil-works/pi-coding-agent, ./write-guard-core.mjs, node:fs, node:path, node:child_process
// @created: 2026-11-19
//
// Зачем (#15739 п.5): `write` перезаписывает файл целиком, и откат держится только на git. В сессии
// #15719 запись заменила `ParityFundingRate.php` словом `placeholder`; восстановление — `git checkout --`.
// Правило и его границы — в write-guard-core.mjs (там же тесты, `node --test tests/write-guard.test.mjs`).
//
// Блокировка без диалога: правка существующего файла делается `edit`, а полная перезапись крупного
// файла — ошибка инструмента, а не решение пользователя.
// Осознанный обход — PI_WRITE_GUARD_ALLOW=1.

import { execFileSync } from "node:child_process";
import { realpathSync, statSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";

import { isToolCallEventType, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { classifyShrink, toToolCallResult } from "./write-guard-core.mjs";

/** Отслеживается ли путь git — спрашиваем сам git, а не угадываем по `.git`. */
function isTracked(path: string, cwd: string): boolean {
	try {
		execFileSync("git", ["ls-files", "--error-unmatch", "--", path], {
			cwd,
			stdio: "ignore",
		});
		return true;
	} catch {
		return false;
	}
}

export default function writeGuard(pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (!isToolCallEventType("write", event)) return undefined;

		const allow = process.env.PI_WRITE_GUARD_ALLOW === "1";
		if (allow) return undefined;

		const target = event.input.path;
		const content = event.input.content;
		if (typeof target !== "string" || typeof content !== "string") return undefined;

		const absolute = isAbsolute(target) ? target : resolve(ctx.cwd, target);

		// stat, а не lstat: симлинк на крупный отслеживаемый файл — это та же перезапись, только цель
		// в другом месте. Проверяется цель, и в находке называется она.
		let stats;
		try {
			stats = statSync(absolute);
		} catch {
			return undefined; // нового файла нет — это и есть штатный случай `write`
		}
		if (!stats.isFile()) return undefined;

		// Цель симлинка, а не сам путь: перезапись по ссылке меняет файл в другом месте.
		let resolved = absolute;
		try {
			resolved = realpathSync(absolute);
		} catch {
			// битый симлинк: писать по нему нельзя, но и сторожить нечего — решение за инструментом
			return undefined;
		}

		// Размер в байтах, а не в символах: кириллица в UTF-8 занимает два байта, и сравнение
		// по длине строки занижало бы старое содержимое вдвое.
		const oldBytes = stats.size;
		const newBytes = Buffer.byteLength(content, "utf8");

		return toToolCallResult(
			classifyShrink({
				oldBytes,
				newBytes,
				tracked: isTracked(resolved, ctx.cwd),
			})
		);
	});
}
