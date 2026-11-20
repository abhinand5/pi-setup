// @file: call-guard-core.mjs
// @description: Решение «пропустить / заблокировать» для bash-вызова — без Pi API.
// @dependencies: нет
// @created: 2026-11-19
//
// Вынесено из call-guard.ts, чтобы правила проверялись тестом без запуска сессии Pi:
// `node --test tests/call-guard.test.mjs`.
//
// Правила (поводы — ретро #15598):
//
// 1. **Вызов без цели** (#15738 п.5). `cd /каталог 2>/dev/null; true` возвращает пустой вывод и ничего
//    не делает: пять таких вызовов в одной сессии, и каждый стоил хода. Правило «в каждом вызове —
//    абсолютный путь к цели» записано в AGENTS.md, но гейта у него не было.
// 2. **Дамп веток и remote без фильтра** (#15749 п.5). `git branch -a` в большом репозитории вернул
//    2168 строк (50 КБ) — весь список веток вместо одной строки ответа. Фильтр — это конвейер:
//    `| wc -l`, `| rg <шаблон>`, `| head`; без него такие команды не печатаются.
// 3. **`sed -i` по файлу** (#15849 п.3). Правило «точечная правка — `edit`, а не `python3 - <<EOF`»
//    жило в AGENTS.md и не меняло поведения: в сессии #15822 после записи правила было 31 правка
//    через heredoc и девять `sed -i`. У `sed -i` нет случая, когда он лучше `edit`: он меняет текст
//    без проверки уникальности вхождения, и диффа до правки не видно. Набор замен через heredoc
//    остаётся разрешённым (это записано в AGENTS.md); блокируется именно in-place правка файла,
//    а `sed` без `-i` (фильтр текста в конвейере) проходит.
//
// Осознанный обход — PI_CALL_GUARD_ALLOW=1 (как у остальных сторожей pi-setup).
//
// Границы названы честно: разбор команд строковый и не знает экранирования вложенного шелла
// (`bash -c '…'`). Ложное срабатывание лечится обходом, а не правкой правила на ходу.

/** Команда, у которой нет полезной части: только переход в каталог, `true`, `:` или `exit 0`. */
const NOOP_SEGMENT = /^(?:true|:)\s*$|^exit(?:\s+0)?\s*$/;

/** `cd <путь>` вместе с типичными перенаправлениями, которыми глушат ошибку перехода. */
const CD_SEGMENT = /^cd\s+[^;&|]+?(?:\s+[012]?>>?\s*\S+|\s+2>&1)*\s*$/;

/**
 * Список веток/remote целиком: `-a`, `--all`, `-r`, `--remotes`, `git remote show <name>` без фильтра.
 *
 * Якорь `^` и проверка по сегменту, а не по строке целиком: `rg -n "git branch -a"` — это поиск
 * текста по репозиторию, а не вызов git, и блокировать его нельзя (такая строка живёт в самом
 * call-guard-core.mjs).
 */
const GIT_BRANCH_LISTING = /^git\s+(?:-C\s+(?:"[^"]*"|'[^']*'|\S+)\s+)?branch\b[^|;]*\s(?:-a|--all|-r|--remotes|--list)\b/;
const GIT_REMOTE_SHOW = /^git\s+(?:-C\s+(?:"[^"]*"|'[^']*'|\S+)\s+)?remote\s+show\b/;

/**
 * `sed -i`, `sed -E -i`, `sed -i.bak`, `sed --in-place`: правка файла на месте.
 *
 * Якорь `^` и `[^|;]*` до флага: `rg -n "sed -i" docs` — поиск текста, а не правка, и блокировать
 * его нельзя. `perl -pi` и heredoc-наборы замен намеренно не трогаются: решение #15849 п.3 выбрало
 * гейт именно на `sed -i`, а многошаговые замены остаются разрешёнными с `assert count==1`.
 */
const SED_IN_PLACE = /^sed\b[^|;]*\s(?:-i\S*|--in-place(?:=\S*)?)(?=\s|$)/;

/**
 * Обёртки перед командой: `sudo`, `command`, `env -u X`, `GIT_PAGER=cat`, `time`, их флаги и
 * присваивания переменных. Снимаются, чтобы правило видело сам вызов: `sudo git branch -a`
 * блокировался и до сужения правил к сегменту. Якорь `^` нужен ровно для того, что НЕ является
 * вызовом git (`rg -n "git branch -a"`).
 */
const WRAPPER = /^(sudo|command|exec|time|env)\b\s*/;
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=\S*\s+/;
const FLAG = /^-{1,2}[^\s]+/;

/**
 * Флаги обёрток, у которых аргумент отдельным словом — свои у каждой обёртки: `-p` у `sudo` — prompt
 * с аргументом, а у `time` — «portable output» без аргумента. Один общий список съедал `git`.
 */
const WRAPPER_ARGUMENT_FLAGS = {
	sudo: new Set(["-u", "--user", "-g", "--group", "-p", "--prompt", "-h", "--host", "-U", "--other-user", "-C", "--close-from"]),
	env: new Set(["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]),
	time: new Set(["-f", "--format", "-o", "--output"]),
	command: new Set(),
	exec: new Set(["-a"]),
};

function unwrapped(segment) {
	let text = segment.trim();
	let wrapperName = null;

	for (;;) {
		let next = null;
		const wrapper = text.match(WRAPPER);
		if (wrapper) {
			wrapperName = wrapper[1];
			next = text.slice(wrapper[0].length).trim();
		} else if (ASSIGNMENT.test(text)) {
			next = text.replace(ASSIGNMENT, "").trim();
		} else if (FLAG.test(text)) {
			const flag = (text.match(FLAG) || [""])[0];
			const rest = text.slice(flag.length).trim();
			const takesArgument = wrapperName !== null
				&& (WRAPPER_ARGUMENT_FLAGS[wrapperName] || new Set()).has(flag);
			next = takesArgument ? rest.replace(/^\S+\s*/, "").trim() : rest;
		}

		if (next === null || next === text || next === "") return next ?? text;
		text = next;
	}
}

/**
 * Разбить команду на сегменты по `;`, `&&`, `||` вне кавычек.
 *
 * Одиночный `|` сегментом НЕ считается: конвейер — это один вызов, и «есть ли фильтр» решается
 * внутри сегмента (`git branch -a | wc -l` — это один сегмент с фильтром).
 *
 * @param {string} command
 * @returns {string[]}
 */
export function splitSegments(command) {
	const segments = [];
	let current = "";
	let quote = null;

	for (let i = 0; i < command.length; i += 1) {
		const char = command[i];
		if (quote) {
			current += char;
			if (char === quote) quote = null;
			continue;
		}
		if (char === '"' || char === "'") {
			quote = char;
			current += char;
			continue;
		}
		const pair = command[i + 1];
		// `2>&1`, `&>file`: `&` здесь часть перенаправления, а не фон — иначе конвейер после него
		// разрезался бы, и `git branch -a 2>&1 | head` падал бы под правило «без фильтра».
		const redirect = char === "&" && (command[i - 1] === ">" || pair === ">");
		if (redirect) {
			current += char;

			continue;
		}
		if (char === ";" || char === "&" || (char === "|" && pair === "|")) {
			segments.push(current);
			current = "";
			// `&&` и `||` — один разделитель из двух символов; одиночный `&` — фон, тоже конец команды.
			if (pair === "&" || (char === "|" && pair === "|")) i += 1;
			continue;
		}
		current += char;
	}
	segments.push(current);

	return segments.map((segment) => segment.trim()).filter((segment) => segment !== "");
}

/**
 * @param {string} command
 * @param {{ allow?: boolean }} [options] allow — осознанный обход (PI_CALL_GUARD_ALLOW=1)
 * @returns {{ allowed: boolean, reason?: string, hint?: string }}
 */
export function classifyCall(command, options = {}) {
	if (options.allow) return { allowed: true };

	const trimmed = command.trim();
	if (trimmed === "") {
		return {
			allowed: false,
			reason: "Пустая команда: вызов без цели.",
			hint: "bash-вызов обязан что-то делать — назовите цель (read/ffgrep для чтения, make/тест для прогона).",
		};
	}

	const segments = splitSegments(trimmed);
	const useful = segments.filter((segment) => !NOOP_SEGMENT.test(segment) && !CD_SEGMENT.test(segment));
	if (useful.length === 0) {
		return {
			allowed: false,
			reason: "Вызов без цели: после `cd` и `;` не остаётся команды, которая что-то делает.",
			hint: "Такой вызов возвращает пустой вывод и ничего не проверяет. Нужен переход ради пути — используйте абсолютный путь в самой команде (`git -C <abs>`, `make -C <abs>`).",
		};
	}

	for (const raw of segments) {
		if (/\|/.test(raw)) continue;
		const segment = unwrapped(raw);

		if (SED_IN_PLACE.test(segment)) {
			return {
				allowed: false,
				reason: "`sed -i` — правка файла на месте, без проверки уникальности вхождения и без диффа.",
				hint: "Точечная правка — `edit` (он требует уникального `oldText` и принимает несколько замен за вызов). Набор замен через heredoc разрешён с `assert count==1`; осознанно — PI_CALL_GUARD_ALLOW=1.",
			};
		}

		if (GIT_BRANCH_LISTING.test(segment)) {
			return {
				allowed: false,
				reason: "Вывод `git branch` без фильтра: список веток всего репозитория (2168 строк, 50 КБ).",
				hint: "Добавьте фильтр: `| wc -l`, `| rg <шаблон>` или `| head`. Нужен весь список осознанно — PI_CALL_GUARD_ALLOW=1.",
			};
		}

		if (GIT_REMOTE_SHOW.test(segment)) {
			return {
				allowed: false,
				reason: "Вывод `git remote show` без фильтра: десятки строк про каждый remote.",
				hint: "Уточните вопрос: `git remote get-url origin`, `git remote show origin | rg <поле>`. Осознанно — PI_CALL_GUARD_ALLOW=1.",
			};
		}
	}

	return { allowed: true };
}

/**
 * Ответ хука Pi: `{ block: true, reason }` либо `undefined`, если вызов проходит.
 *
 * @param {{ allowed: boolean, reason?: string, hint?: string }} verdict
 */
export function toToolCallResult(verdict) {
	if (verdict.allowed) return undefined;

	const lines = [`Call Guard blocked: ${verdict.reason ?? "вызов без цели"}`, ...(verdict.hint ? [verdict.hint] : [])];
	return { block: true, reason: lines.join("\n") };
}
