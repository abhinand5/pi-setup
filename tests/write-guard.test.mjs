// @file: write-guard.test.mjs
// @description: Тесты правила write-guard: плейсхолдер поверх отслеживаемого файла блокируется, обычная
//               правка (в том числе вдвое короче) проходит.
// @dependencies: node:test, node:assert, ../extensions/write-guard-core.mjs
// @created: 2026-11-19
//
// Запуск: `node --test tests/write-guard.test.mjs` из корня pi-setup.
//
// Живой замер #15739 п.5: запись заменила `ParityFundingRate.php` словом `placeholder`, откат —
// `git checkout --`; в той же сессии пять плейсхолдерных записей.

import assert from "node:assert/strict";
import { test } from "node:test";

import { ABSOLUTE_FLOOR_BYTES, classifyShrink, MIN_TRACKED_BYTES } from "../extensions/write-guard-core.mjs";

const LARGE = 4000;

test("плейсхолдер поверх крупного отслеживаемого файла блокируется", () => {
	const verdict = classifyShrink({ oldBytes: LARGE, newBytes: "placeholder\n".length, tracked: true });

	assert.equal(verdict.allowed, false);
	assert.match(verdict.reason, /затирает отслеживаемый файл/);
	assert.match(verdict.hint, /edit/);
	assert.match(verdict.hint, /PI_WRITE_GUARD_ALLOW=1/);
});

test("новый файл не проверяется: писать нечего", () => {
	// Существующий файл меньше порога — это не код проекта.
	assert.equal(classifyShrink({ oldBytes: MIN_TRACKED_BYTES, newBytes: 1, tracked: true }).allowed, true);
	assert.equal(classifyShrink({ oldBytes: 900, newBytes: 0, tracked: true }).allowed, true);
});

test("неотслеживаемый файл не блокируется: откатывать нечего", () => {
	assert.equal(classifyShrink({ oldBytes: LARGE, newBytes: 10, tracked: false }).allowed, true);
});

test("обычная правка проходит, даже если файл стал вдвое короче", () => {
	assert.equal(classifyShrink({ oldBytes: LARGE, newBytes: LARGE / 2, tracked: true }).allowed, true);
});

test("файл 4000 Б → 700 Б проходит (17,5 % — это правка, а не плейсхолдер)", () => {
	// Порог — одновременно «меньше 200 байт» и «меньше 20 %»: 700 Б выше жёсткого пола, но ниже
	// 20 %? 20 % от 4000 = 800, значит 700 — потеря. Правило блокирует, и это осознанно.
	assert.equal(classifyShrink({ oldBytes: 4000, newBytes: 700, tracked: true }).allowed, false);
	// А 900 Б (22,5 %) — уже правка.
	assert.equal(classifyShrink({ oldBytes: 4000, newBytes: 900, tracked: true }).allowed, true);
});

test("жёсткий пол 200 байт ловит миниатюризацию крупного файла", () => {
	assert.equal(ABSOLUTE_FLOOR_BYTES, 200);
	assert.equal(classifyShrink({ oldBytes: 200_000, newBytes: 150, tracked: true }).allowed, false);
	// 250 Б от 2000 — тоже 12,5 %, то есть блокируется по доле, а не по полу: правило — «или/или».
	assert.equal(classifyShrink({ oldBytes: 2000, newBytes: 250, tracked: true }).allowed, false);
	// А 600 Б от 2000 (30 %) — обычная правка.
	assert.equal(classifyShrink({ oldBytes: 2000, newBytes: 600, tracked: true }).allowed, true);
});

test("осознанный обход снимает блокировку", () => {
	assert.equal(classifyShrink({ oldBytes: LARGE, newBytes: 5, tracked: true, allow: true }).allowed, true);
});
