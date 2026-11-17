// @file: path-guard.test.mjs
// @description: Тесты правил path-guard: шелл-символы, управляющие символы, абсолютные пути мимо cwd/$HOME//tmp.
// @dependencies: node:test, node:assert, ../extensions/path-guard-core.mjs
// @created: 2026-11-18
//
// Запуск: `node --test tests/path-guard.test.mjs` из корня pi-setup.
//
// Первый кейс — живой замер из #15723 п.5: именно этот аргумент создал каталог `/home/denis/work 2>`
// в домашнем каталоге, и нашёлся он двадцать вызовов спустя.

import assert from "node:assert/strict";
import { test } from "node:test";

import { checkPath, toToolCallResult } from "../extensions/path-guard-core.mjs";

const CWD = "/home/denis/work/msl/msb-lk";
const ROOTS = ["/home/denis/work/msl/msb-lk", "/home/denis", "/tmp"];

function check(path, cwd = CWD) {
	return checkPath(path, cwd, { roots: ROOTS });
}

test("путь с `2>/dev/null` блокируется — живой замер #15723 п.5", () => {
	const verdict = check("/home/denis/work 2>/dev/null");
	assert.equal(verdict.allowed, false);
	assert.match(verdict.reason, /шелл-символ `>`/);
	assert.match(verdict.reason, /bash/);
});

test("каждый шелл-символ в пути блокируется", () => {
	for (const symbol of [">", "<", "|", ";", "&", "`", "$", "*", "?", "(", ")", "{", "}", "[", "]", "!"]) {
		const verdict = check(`/home/denis/work/msl/msb-lk/out${symbol}x.md`);
		assert.equal(verdict.allowed, false, `символ ${symbol} пропущен`);
	}
});

test("управляющие символы и хвостовой пробел блокируются", () => {
	assert.equal(check("docs/\nfile.md").allowed, false);
	assert.equal(check("docs/file\u0000.md").allowed, false);
	assert.equal(check("docs/file.md ").allowed, false);
	assert.equal(check("docs/file.md\t").allowed, false);
});

test("пустой путь блокируется", () => {
	assert.equal(check("").allowed, false);
	assert.equal(check("   ").allowed, false);
});

test("обычный относительный путь проходит", () => {
	assert.deepEqual(check("docs/dev/notes.md"), {
		allowed: true,
		absolutePath: "/home/denis/work/msl/msb-lk/docs/dev/notes.md",
	});
});

test("абсолютный путь внутри cwd, $HOME и /tmp проходит", () => {
	assert.equal(check("/home/denis/work/msl/msb-lk/docs/a.md").allowed, true);
	assert.equal(check("/home/denis/tmp/a.md").allowed, true);
	assert.equal(check("/tmp/pi-notes.md").allowed, true);
});

test("абсолютный путь мимо рабочего дерева блокируется", () => {
	const verdict = check("/etc/hosts");
	assert.equal(verdict.allowed, false);
	assert.match(verdict.reason, /вне рабочего каталога/);
	assert.match(verdict.reason, /bash/);
});

test("префикс соседнего каталога не считается вложенным", () => {
	// /home/denis/work-2 не должен проходить как «внутри /home/denis» — сравнение по границе пути.
	assert.equal(check("/home/denis-other/a.md").allowed, false);
});

test("кириллический гомоглиф в пути не блокируется — это другой класс ошибки", () => {
	// Гомоглиф создаёт лишний каталог, но шелл-символа в нём нет: ловить его должен не этот гейт.
	assert.equal(check("/home/denis/п/a.md").allowed, true);
});

test("ответ Pi для заблокированного вызова называет причину", () => {
	const result = toToolCallResult(check("/home/denis/work 2>/dev/null"));
	assert.equal(result.block, true);
	assert.match(result.reason, /path-guard/);
	assert.match(result.reason, /шелл-символ/);
});

test("пропущенный вызов не возвращает блокировку", () => {
	assert.equal(toToolCallResult(check("docs/a.md")), undefined);
});
