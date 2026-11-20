// @file: bin-help.test.mjs
// @description: У каждого хелпера в `bin/` справка проверяется прогоном, а не ревьюером (#15849 п.4):
//               `--help` — код 0, не меньше трёх строк справки, в вывод не попадает код скрипта.
//               Делегирующие хелперы (`pi`, `rg`, `redmine-file`) запускаются с заглушками в PATH:
//               справка не должна требовать установленного инструмента — ровно тот случай, когда её
//               и зовут (на чужой машине, в CI, сразу после `install.sh`).
// @dependencies: node:test, node:assert, node:child_process
// @created: 2026-11-20
//
// Запуск: `node --test tests/bin-help.test.mjs` из корня pi-setup.
//
// Повод — `docker/scripts/calculator-switch.sh` в msb-lk: его первая версия печатала на `--help` строку
// `set -euo pipefail` и выходила кодом 1 (`sed -n '2,24p'` при шапке в 22 строки). Поймало ревью.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const BIN_DIR = join(ROOT, "bin");

/** Инструменты, которые хелперы зовут: заглушки отвечают справкой и кодом 0. */
const DELEGATES = ["pi", "rg", "redmine", "hunspell", "node", "php", "git", "docker", "mysql"];

function stubDirectory() {
	const dir = mkdtempSync(join(tmpdir(), "pi-bin-stub-"));
	for (const name of DELEGATES) {
		const path = join(dir, name);
		writeFileSync(path, `#!/bin/sh\nprintf 'ЗАГЛУШКА ${name}: справка\\nстрока 2\\nстрока 3\\n'\n`);
		chmodSync(path, 0o755);
	}

	return dir;
}

test("каждый bin/* отвечает на --help кодом 0 и настоящей справкой", () => {
	const stubs = stubDirectory();
	// Только обычные файлы: `bin/__pycache__` появляется от `python3 -m py_compile bin/ru-spellcheck`
	// (шаг CI прямо перед этим тестом, и та же команда в ручной проверке). Каталог в списке давал
	// `--help` с кодом null, то есть красный CI на ровном месте — в сессии #15861 локальный прогон
	// был зелёным только потому, что `__pycache__` ещё не успел появиться.
	const helpers = readdirSync(BIN_DIR, { withFileTypes: true })
		.filter((entry) => entry.isFile() && !entry.name.startsWith("."))
		.map((entry) => entry.name)
		.sort();
	assert.ok(helpers.length >= 3, `в bin/ нечего проверять: ${helpers.join(", ")}`);

	const failures = [];

	for (const name of helpers) {
		const path = join(BIN_DIR, name);
		// Запуск по shebang, а не `bash <скрипт>`: `bin/ru-spellcheck` — python-скрипт, и bash
		// спотыкался на его синтаксисе, то есть тест мерил бы не справку, а обёртку.
		const result = spawnSync(path, ["--help"], {
			cwd: ROOT,
			encoding: "utf8",
			timeout: 20000,
			env: {
				PATH: `${stubs}:/usr/local/bin:/usr/bin:/bin`,
				HOME: stubs,
				TMPDIR: stubs,
			},
		});

		const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
		const lines = output.split("\n").filter((line) => line.trim() !== "");

		if (result.status !== 0) {
			failures.push(`${name}: --help вернул код ${result.status}\n${output}`);
			continue;
		}
		if (lines.length < 3) {
			failures.push(`${name}: справка короче трёх строк\n${output}`);
		}
		if (/^set -e/m.test(output)) {
			failures.push(`${name}: в справку попал код скрипта (set -e…)\n${output}`);
		}
	}

	assert.deepEqual(failures, [], `справка bin/*:\n${failures.join("\n\n")}`);
});
