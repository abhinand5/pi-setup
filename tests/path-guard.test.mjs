// @file: path-guard.test.mjs
// @description: Тесты правил path-guard: шелл-символы, управляющие символы, абсолютные пути мимо
//               cwd/$HOME//tmp, каталог-двойник по гомоглифу, запись в основное дерево из воркдерева.
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

// Корни те же, что у живой сессии. Обход правила 7 включён в помощнике: кейсы ниже проверяют другие
// правила, а часть их путей лежит в `~/p/pi-setup` (списки ru-spellcheck). Само правило 7 проверяется
// отдельно и вызывает `checkPath` без обхода.
function check(path, cwd = CWD) {
	return checkPath(path, cwd, { roots: ROOTS, allowPiSetupMain: true });
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

// Правило двойника проверяется на подставленной ФС, а не на настоящей: тест обязан быть переносимым
// (репозиторий — «restore config across machines», и на macOS нет ни /home/denis, ни тех же каталогов).
function fsFrom(paths) {
	const existing = new Set();
	const children = new Map();
	for (const path of paths) {
		// Родители существуют по определению: проверяется только первый несуществующий уровень.
		const parts = path.split("/").filter((part) => part !== "");
		let prefix = "";
		for (const part of parts) {
			prefix += "/" + part;
			existing.add(prefix);
			const slash = prefix.lastIndexOf("/");
			const parent = slash === 0 ? "/" : prefix.slice(0, slash);
			if (!children.has(parent)) children.set(parent, []);
			children.get(parent).push(part);
		}
	}
	return {
		exists: (path) => existing.has(path),
		readdir: (dir) => {
			if (!children.has(dir)) throw new Error("ENOENT: " + dir);
			return children.get(dir);
		},
	};
}

function checkWithFs(path, paths, cwd = CWD, extra = {}) {
	const fs = fsFrom(paths);
	return checkPath(path, cwd, { roots: ROOTS, exists: fs.exists, readdir: fs.readdir, ...extra });
}

test("каталог-двойник по гомоглифу блокируется — замер #15743 п.1", () => {
	// Живой случай: `write` с путём /home/denis/п/p/pi-setup-wt/… создал четыре уровня каталогов
	// в домашнем каталоге рядом с /home/denis/p. Шелл-символа в таком пути нет, поэтому его ловило
	// только правило двойника.
	const verdict = checkWithFs("/home/denis/п/a.md", ["/home/denis", "/home/denis/p"]);
	assert.equal(verdict.allowed, false);
	assert.match(verdict.reason, /рядом уже есть \/home\/denis\/p —/);
	assert.match(verdict.reason, /гомоглиф/);
});

test("новый уровень без соседа-двойника пропускается", () => {
	assert.equal(checkWithFs("/home/denis/work/msl/a.md", ["/home/denis"]).allowed, true);
});

test("уровни ниже первого нового не проверяются — родителей у них ещё нет", () => {
	// /home/denis/p существует, значит первый новый уровень — «новый-каталог»; соседи есть только
	// у него, и двойника среди них нет.
	const verdict = checkWithFs("/home/denis/p/новый-каталог/файл.md", ["/home/denis", "/home/denis/p"]);
	assert.equal(verdict.allowed, true);
});

test("гомоглиф в имени нового уровня внутри существующего каталога блокируется", () => {
	// «тests» той же длины, что существующий «tests»: т→t, остальные символы совпадают.
	const verdict = checkWithFs("/home/denis/p/pi-setup/тests/x.md", [
		"/home/denis",
		"/home/denis/p",
		"/home/denis/p/pi-setup",
		"/home/denis/p/pi-setup/tests",
	]);
	assert.equal(verdict.allowed, false);
	assert.match(verdict.reason, /гомоглиф/);
});

test("регистр — не гомоглиф: P рядом с p не блокируется", () => {
	// На Linux это законно разные каталоги; блокировать значило бы ложно срабатывать там, где ФС
	// регистрозависима. Осознанное сужение описано в шапке модуля.
	assert.equal(checkWithFs("/home/denis/P/a.md", ["/home/denis", "/home/denis/p"]).allowed, true);
});

test("осознанный обход двойника проходит", () => {
	const verdict = checkWithFs(
		"/home/denis/п/a.md",
		["/home/denis", "/home/denis/p"],
		CWD,
		{ allowTwin: true },
	);
	assert.equal(verdict.allowed, true);
});

test("запись в основное дерево при активном воркдереве блокируется — #15742 п.5", () => {
	const worktree = "/home/denis/work/msl/msb-lk/.claude/worktrees/15820-tooling";
	const verdict = checkPath("/home/denis/work/msl/msb-lk/tmp/probe.txt", worktree, { roots: ROOTS });
	assert.equal(verdict.allowed, false);
	assert.match(verdict.reason, /в основном дереве/);
	assert.match(verdict.reason, /PI_PATH_GUARD_ALLOW_MAIN_TREE=1/);
});

test("правило основного дерева работает и из подкаталога воркдерева", () => {
	// ctx.cwd — текущий каталог: сессия может стоять в modules/ или extensions/, и правило не должно
	// молча выключаться из-за подкаталога.
	const worktree = "/home/denis/work/msl/msb-lk/.claude/worktrees/15820-tooling";
	const verdict = checkPath("/home/denis/work/msl/msb-lk/tmp/probe.txt", `${worktree}/modules/leasing`, {
		roots: ROOTS,
	});
	assert.equal(verdict.allowed, false);
	assert.match(verdict.reason, /в основном дереве/);
});

test("запись внутри своего воркдерева пропускается", () => {
	const worktree = "/home/denis/work/msl/msb-lk/.claude/worktrees/15820-tooling";
	const verdict = checkPath(`${worktree}/tmp/probe.txt`, worktree, { roots: ROOTS });
	assert.equal(verdict.allowed, true);
});

test("родная раскладка pi-setup `<repo>-wt/<задача>` тоже покрыта", () => {
	// config/AGENTS.md: git worktree add ../pi-setup-wt/<задача>-<слаг>. Без этой ветки правило молчало
	// бы в самом репозитории, который везёт сторожа.
	const worktree = "/home/denis/p/pi-setup-wt/15820-path-guard";
	const verdict = checkPath("/home/denis/p/pi-setup/extensions/path-guard.ts", worktree, { roots: ROOTS });
	assert.equal(verdict.allowed, false);
	assert.match(verdict.reason, /в основном дереве/);

	const inside = checkPath(`${worktree}/extensions/path-guard-core.mjs`, worktree, { roots: ROOTS });
	assert.equal(inside.allowed, true);
});

test("вырожденный корень `/.claude/worktrees/x` не блокирует всё подряд", () => {
	// isUnder(path, "") истинно для любого абсолютного пути: пустой корень в правиле означал бы
	// блокировку любой записи, включая /tmp.
	const verdict = checkPath("/tmp/probe.md", "/.claude/worktrees/15820", { roots: ROOTS });
	assert.equal(verdict.allowed, true);
});

test("осознанный обход записи в основное дерево проходит", () => {
	const worktree = "/home/denis/work/msl/msb-lk/.claude/worktrees/15820-tooling";
	const verdict = checkPath("/home/denis/work/msl/msb-lk/tmp/probe.txt", worktree, { roots: ROOTS, allowMainTree: true });
	assert.equal(verdict.allowed, true);
});

test("вне воркдерева правило основного дерева не срабатывает", () => {
	const verdict = checkPath("/home/denis/work/msl/msb-lk/tmp/probe.txt", "/home/denis/work/msl/msb-lk", { roots: ROOTS });
	assert.equal(verdict.allowed, true);
});

test("списки запрещённых слов ru-spellcheck не редактируются — #15820", () => {
	// Агент, который может править deny-список, узаконивает собственную лексику: проверка после этого
	// ничего не значит. Оба пути: машинный список и проектный файл.
	for (const path of [
		"/home/denis/.config/ru-spellcheck/deny.txt",
		"/home/denis/p/pi-setup/config/ru-spellcheck/deny.txt",
		"/home/denis/p/msl/msb-lk/.ru-spellcheck-deny",
	]) {
		const verdict = check(path);
		assert.equal(verdict.allowed, false, `правка разрешена: ${path}`);
		assert.match(verdict.reason, /список запрещённых слов/);
		assert.match(verdict.reason, /PI_PATH_GUARD_ALLOW_DENY_LIST=1/);
	}
});

test("обычные файлы рядом с deny-списком не задеты", () => {
	// allow-список пополняется агентом по замыслу (--add), поэтому запрет только на deny.
	assert.equal(check("/home/denis/.config/ru-spellcheck/allow.txt").allowed, true);
	assert.equal(check("/home/denis/p/pi-setup/.ru-spellcheck-allow").allowed, true);
	assert.equal(check("/home/denis/p/pi-setup/config/ru-spellcheck/deny.md").allowed, true);
});

test("осознанный обход запрета deny-списка проходит", () => {
	const verdict = checkPath("/home/denis/p/pi-setup/config/ru-spellcheck/deny.txt", CWD, {
		roots: ROOTS,
		allowDenyList: true,
		// Кейс про обход deny-списка, а не про правило 7: путь лежит в общем чекауте pi-setup.
		allowPiSetupMain: true,
	});
	assert.equal(verdict.allowed, true);
});

// #16046 п.4: сессия работала из основного дерева msb-lk, и `edit` ушёл в общий чекаут pi-setup
// (`~/p/pi-setup/skills/browser-uat/uct-login.mjs`) — правило 5 такую сессию не ловило, потому что она
// не в воркдереве pi-setup. Политика «pi-setup правится в воркдереве» держалась только текстом.
const PI_SETUP_ROOT = "/home/denis/p/pi-setup";

function checkPiSetup(path, extra = {}) {
	return checkPath(path, CWD, { roots: ROOTS, piSetupRoot: PI_SETUP_ROOT, ...extra });
}

test("правка в общем чекауте pi-setup блокируется и называет воркдерево — #16046 п.4", () => {
	for (const path of [
		"/home/denis/p/pi-setup/skills/browser-uat/uct-login.mjs",
		"/home/denis/p/pi-setup/config/AGENTS.md",
		"/home/denis/p/pi-setup/AGENTS.md",
	]) {
		const verdict = checkPiSetup(path);
		assert.equal(verdict.allowed, false, `правка разрешена: ${path}`);
		assert.match(verdict.reason, /общем чекауте/, `причина не та: ${verdict.reason}`);
		assert.match(verdict.reason, /pi-setup-wt\/<задача>/, `воркдерево не названо: ${verdict.reason}`);
		assert.match(verdict.reason, /PI_PATH_GUARD_ALLOW_PI_SETUP_MAIN=1/);
	}
});

test("правка в воркдереве pi-setup проходит — #16046 п.4", () => {
	assert.equal(checkPiSetup("/home/denis/p/pi-setup-wt/16046-retro/skills/pr/SKILL.md").allowed, true);
});

test("осознанный обход запрета общего чекаута pi-setup проходит", () => {
	const verdict = checkPiSetup("/home/denis/p/pi-setup/skills/pr/SKILL.md", { allowPiSetupMain: true });
	assert.equal(verdict.allowed, true);
});

test("правило 7 не задевает чужие каталоги и соседей pi-setup", () => {
	// Соседний каталог с тем же префиксом — не общий чекаут: сравнение идёт по границе каталога.
	assert.equal(checkPiSetup("/home/denis/p/pi-setup-other/skills/pr/SKILL.md").allowed, true);
	assert.equal(checkPiSetup("/home/denis/p/msl/msb-lk/AGENTS.md").allowed, true);
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
