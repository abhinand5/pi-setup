// @file: extensions-load.test.mjs
// @description: Каждое расширение `extensions/*.ts` должно загружаться и отдавать функцию — иначе
//               Pi молча теряет сторожа.
// @dependencies: node:test, node:assert, node:fs, node:os, node:path
// @created: 2026-11-19
//
// Зачем: `node --check` на `.ts` возвращает 0 даже при дубле объявления в одной области
// (`let target = …` рядом с `const target = …`), а `node --test` проверял только `*-core.mjs` —
// сами расширения не грузил никто. Так в #15822 уехал `extensions/write-guard.ts`, который падал
// на загрузке с `SyntaxError: Identifier 'target' has already been declared`: сторож записи был мёртв,
// а все тесты зелёные.
//
// Как грузим: копия расширения во временный каталог, где peer-зависимость
// `@earendil-works/pi-coding-agent` заменена заглушкой (в CI пакета Pi нет). Типы снимает
// `--experimental-strip-types`, поэтому запуск — `node --experimental-strip-types --test tests/*.test.mjs`.
//
// Мутация для проверки живости теста: добавить в любое `.ts` расширение второе объявление той же
// переменной в той же области — тест обязан упасть.

import assert from "node:assert/strict";
import { cpSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

const ROOT = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const EXTENSIONS = join(ROOT, "extensions");

/**
 * Заглушки peer-зависимостей. Экспорты не перечисляются руками: имена собираются из самих
 * расширений, иначе тест ломается на каждом новом импорте, а проверить надо одно — модуль
 * разбирается и грузится. Поведение нужно только двум функциям, остальное — заглушки.
 */
function importedNames(source) {
	const names = new Set();
	const pattern = /import\s+(?:type\s+)?\{([^}]*)\}\s+from\s+"@earendil-works\/pi-(?:coding-agent|tui)"/g;
	for (const match of source.matchAll(pattern)) {
		for (const raw of match[1].split(",")) {
			const name = raw.trim().replace(/^type\s+/, "").split(/\s+as\s+/)[0].trim();
			if (name) names.add(name);
		}
	}
	return names;
}

function stubSource(names) {
	const lines = [];
	for (const name of names) {
		if (name === "isToolCallEventType") {
			lines.push('export function isToolCallEventType(type, event) { return event?.toolName === type; }');
		} else if (name === "matchesKey") {
			lines.push("export const matchesKey = () => false;");
		} else {
			lines.push(`export const ${name} = undefined;`);
		}
	}

	return lines.join("\n") + "\n";
}

/** Карта «расширение → имя экспорта по умолчанию» не нужна: контракт у всех один. */
function extensionFiles() {
	return readdirSync(EXTENSIONS).filter((name) => name.endsWith(".ts"));
}

test("каждое расширение загружается и отдаёт функцию", async () => {
	const files = extensionFiles();
	assert.ok(files.length > 0, "в extensions/ нет .ts — тест потерял охват");

	const failures = [];
	for (const file of files) {
		const work = mkdtempSync(join(tmpdir(), "pi-ext-load-"));
		try {
			// Копируем всё: расширение может импортировать соседний `*-core.mjs`.
			cpSync(EXTENSIONS, join(work, "extensions"), { recursive: true });
			const path = join(work, "extensions", file);
			const original = readFileSync(path, "utf8");
			// Имена собираются ДО замены импортов: после неё пакета в тексте уже нет.
			const names = importedNames(original);
			const rewritten = original
				.replaceAll('"@earendil-works/pi-coding-agent"', '"./stub-pi.mjs"')
				.replaceAll('"@earendil-works/pi-tui"', '"./stub-tui.mjs"');

			// Заглушки лежат рядом с расширениями: импорт в них относительный (`./stub-pi.mjs`).
			writeFileSync(join(work, "extensions", "stub-pi.mjs"), stubSource(names));
			writeFileSync(join(work, "extensions", "stub-tui.mjs"), stubSource(names));
			writeFileSync(path, rewritten);

			const loaded = await import(pathToFileURL(path).href + `?t=${Date.now()}-${file}`);
			if (typeof loaded.default !== "function") {
				failures.push(`${file}: default — не функция`);
			}
		} catch (error) {
			failures.push(`${file}: ${error?.message ?? error}`);
		} finally {
			rmSync(work, { recursive: true, force: true });
		}
	}

	assert.deepEqual(failures, [], "расширения, которые не загружаются:\n" + failures.join("\n"));
});
