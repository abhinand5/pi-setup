// @file: call-guard.test.mjs
// @description: Тесты правил call-guard: вызов без цели, `git branch -a`/`git remote show` без фильтра,
//               отсутствие ложных срабатываний на командах, где `cd` — часть рабочего вызова.
// @dependencies: node:test, node:assert, ../extensions/call-guard-core.mjs
// @created: 2026-11-19
//
// Запуск: `node --test tests/call-guard.test.mjs` из корня pi-setup.
//
// Первые кейсы — живые замеры: #15738 п.5 (`cd … 2>/dev/null; true` пять раз за сессию) и
// #15749 п.5 (`git branch -a` → 2168 строк, 50 КБ).

import assert from "node:assert/strict";
import { test } from "node:test";

import { classifyCall, splitSegments } from "../extensions/call-guard-core.mjs";

test("пустой вызов после cd блокируется — замер #15738 п.5", () => {
	const verdict = classifyCall("cd /home/denis/p/msl/msb-lk 2>/dev/null; true");
	assert.equal(verdict.allowed, false);
	assert.match(verdict.reason, /без цели/);
	assert.match(verdict.hint, /git -C|make -C/);
});

test("голый `:` и `exit 0` — тоже вызов без цели", () => {
	assert.equal(classifyCall("cd /tmp; :").allowed, false);
	assert.equal(classifyCall("cd /tmp && exit 0").allowed, false);
	assert.equal(classifyCall("true").allowed, false);
});

test("cd с полезной частью проходит", () => {
	assert.equal(classifyCall("cd /repo && make test").allowed, true);
	assert.equal(classifyCall("cd /repo 2>/dev/null; rg -n 'foo' src/").allowed, true);
	assert.equal(classifyCall("git -C /repo status --short").allowed, true);
});

test("git branch -a без фильтра блокируется — замер #15749 п.5", () => {
	for (const command of ["git branch -a", "git branch --all", "git branch -r", "git branch --remotes"]) {
		const verdict = classifyCall(command);
		assert.equal(verdict.allowed, false, command);
		assert.match(verdict.reason, /git branch/, command);
		assert.match(verdict.hint, /wc -l/, command);
	}
});

test("git branch с фильтром проходит", () => {
	assert.equal(classifyCall("git branch -a | wc -l").allowed, true);
	assert.equal(classifyCall("git branch -a | rg 15822").allowed, true);
	assert.equal(classifyCall("git branch -a | head -20").allowed, true);
});

test("git branch -d (удаление) правилом не трогается: это другой сторож", () => {
	assert.equal(classifyCall("git branch -d fix/15822-tooling-guards").allowed, true);
});

test("git remote show без фильтра блокируется, get-url проходит", () => {
	assert.equal(classifyCall("git remote show origin").allowed, false);
	assert.equal(classifyCall("git remote show origin | rg Fetch").allowed, true);
	assert.equal(classifyCall("git remote get-url origin").allowed, true);
});

test("осознанный обход снимает блокировку", () => {
	assert.equal(classifyCall("git branch -a", { allow: true }).allowed, true);
	assert.equal(classifyCall("cd /tmp; true", { allow: true }).allowed, true);
});

test("сегменты режутся по ; && || вне кавычек", () => {
	assert.deepEqual(splitSegments("cd /a; true"), ["cd /a", "true"]);
	assert.deepEqual(splitSegments("cd /a && a || b"), ["cd /a", "a", "b"]);
	assert.deepEqual(splitSegments('echo "a;b"'), ['echo "a;b"']);
	// Одиночный `|` — не граница сегмента: конвейер один вызов, и фильтр считается внутри него.
	assert.deepEqual(splitSegments("git branch -a | wc -l"), ["git branch -a | wc -l"]);
});

// Поиск текста по репозиторию — не вызов git: строку `git branch -a` ищут в этом самом файле
// (`rg -n "git branch -a" extensions/`), и блокировать такой поиск нельзя.
test("упоминание в кавычках не блокируется", () => {
	assert.equal(classifyCall('rg -n "git branch -a" /abs').allowed, true);
	assert.equal(classifyCall('echo "git branch -a"').allowed, true);
});

// Обратная сторона: блокируется сегмент без фильтра, даже если фильтр есть у соседнего вызова.
test("фильтр соседнего сегмента не спасает", () => {
	assert.equal(classifyCall("git branch -a; ls /tmp | head").allowed, false);
	assert.equal(classifyCall("cd /repo && git branch -a").allowed, false);
});

// Обёртки перед вызовом не должны прятать правило: до сужения к сегменту они блокировались,
// и терять это покрытие незачем (находка ревью раунда 2).
test("обёртки и присваивания перед git не прячут вызов", () => {
	for (const command of [
		"sudo git branch -a",
		"env -u X git branch -a",
		"GIT_PAGER=cat git branch -a",
		"time git remote show origin",
		'git -C "/a b" branch -a',
		"cd /a & git branch -a",
	]) {
		assert.equal(classifyCall(command).allowed, false, command);
	}
});

test("одиночный & — конец команды, конвейер — нет", () => {
	assert.deepEqual(splitSegments("cd /a & ls"), ["cd /a", "ls"]);
	assert.deepEqual(splitSegments("a && b"), ["a", "b"]);
	assert.deepEqual(splitSegments("a | b"), ["a | b"]);
});

// Перенаправление `2>&1` не разрывает конвейер: `&` в нём — часть редиректа, а не фон.
// Регрессия раунда 3: `git branch -a 2>&1 | head` блокировался, хотя фильтр в команде есть.
test("редирект 2>&1 не разрывает конвейер и не даёт ложный блок", () => {
	for (const command of [
		"git branch -a 2>&1 | head",
		"git branch -a 2>&1 | wc -l",
		"git remote show origin 2>&1 | rg URL",
	]) {
		assert.equal(classifyCall(command).allowed, true, command);
	}
	assert.deepEqual(splitSegments("git branch -a 2>&1 | head"), ["git branch -a 2>&1 | head"]);
});

// Флаги обёрток снимаются по своей таблице: `-p` у `time` — без аргумента, у `sudo` — с ним.
test("флаги обёрток не съедают сам git", () => {
	for (const command of [
		"sudo -n git branch -a",
		"sudo -u deploy git branch -a",
		"env -i git branch -a",
		"env -u X git branch -a",
		"time -p git branch -a",
		"time -f %e git branch -a",
		"command -p git branch -a",
	]) {
		assert.equal(classifyCall(command).allowed, false, command);
	}
	assert.equal(classifyCall("time make test").allowed, true);
	assert.equal(classifyCall("sudo apt-get install -y jq").allowed, true);
});

// Правило 3 (#15849 п.3): `sed -i` — правка файла на месте. Правило «точечная правка — edit»
// жило в AGENTS.md и не меняло поведения: в сессии #15822 после записи правила было 31 правка
// через heredoc и девять `sed -i`.
test("sed -i блокируется во всех обычных формах", () => {
	for (const command of [
		"sed -i 's/a/b/' src/Foo.php",
		"sed -i.bak -e 's/a/b/' src/Foo.php",
		"sed -E -i 's/(a)/b/' src/Foo.php",
		"sed -n -i 's/a/b/p' src/Foo.php",
		"sed --in-place 's/a/b/' src/Foo.php",
		"sed --in-place=.bak 's/a/b/' src/Foo.php",
		"cd /repo && sed -i 's/a/b/' src/Foo.php",
		"sudo sed -i 's/a/b/' /etc/hosts",
	]) {
		const verdict = classifyCall(command);
		assert.equal(verdict.allowed, false, command);
		assert.match(verdict.reason, /sed -i/, command);
		assert.match(verdict.hint, /edit/, command);
	}
});

// Обратная сторона: `sed` без `-i` — фильтр текста, его блокировать нельзя; поиск строки «sed -i»
// по репозиторию и heredoc-набор замен тоже проходят (решение #15849 п.3 их разрешает).
test("sed без -i, поиск упоминания и heredoc не блокируются", () => {
	for (const command of [
		"sed -n '1,20p' src/Foo.php",
		"sed 's/a/b/' src/Foo.php | head",
		'rg -n "sed -i" docs/',
		"python3 - <<'PY'\nimport io\nPY",
	]) {
		assert.equal(classifyCall(command).allowed, true, command);
	}
});

test("sed -i снимается осознанным обходом", () => {
	assert.equal(classifyCall("sed -i 's/a/b/' src/Foo.php", { allow: true }).allowed, true);
});
