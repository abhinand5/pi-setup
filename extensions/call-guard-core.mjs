// @file: call-guard-core.mjs
// @description: Решение «пропустить / заблокировать» для bash-вызова — без Pi API.
// @dependencies: node:fs (размер файла в правиле чтения)
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
// 4. **Чтение файла и поиск по всему домашнему каталогу через bash** (#15906 п.4, #15909 п.4). Правило
//    «файл читает `read`, поиск делает `ffgrep`/`fffind`» жило в AGENTS.md и не держалось: 26 вызовов
//    `sed -n 'N,Mp'` против 6 `read` в одной сессии, около 20 `sed -n` и 30 `grep -n`/`ls` в другой,
//    а два `grep -r … /home/денis` умерли по таймауту (60 с и 10 с). Файл до 50 КБ читается только
//    `read` с `offset`/`limit`; файл больше 50 КБ и конвейер не трогаются.
//
//    С #16110 отказ у этого правила приходит вместе с содержимым: у `cat`, `sed -n 'A,Bp'` и `grep -n`
//    по файлу до 50 КБ в тексте отказа стоят запрошенные строки с номерами. Причина — замер: 6–7
//    отказов за сессию (#16074 — 3, #16048 — 7, #16110 — 6–7), и каждый стоил хода на повтор той же
//    цели законным инструментом. Функция сторожа может только заблокировать вызов и подменить
//    аргументы (`tool_call` в Pi не умеет вернуть результат другого инструмента), поэтому содержимое
//    едет в тексте отказа. Отдаётся только первая область (как `read` с `limit`) и только один файл;
//    для остального в отказе назван `offset`, с которого читать.
//
// Осознанный обход — PI_CALL_GUARD_ALLOW=1 (как у остальных сторожей pi-setup).
//
// Границы названы честно: разбор команд строковый и не знает экранирования вложенного шелла
// (`bash -c '…'`). Ложное срабатывание лечится обходом, а не правкой правила на ходу.

import { readFileSync, statSync } from "node:fs";

/** Порог «файл больше 50 КБ»: такой файл через `sed -n`/`cat` читать разрешено (51200 байт). */
const READ_LIMIT_BYTES = 51200;

/** Диапазон печати `sed -n`: `1,20p`, `5p`, `120,400p`. */
const SED_PRINT_RANGE = /^\d+(?:,\d+)?p$/;

/**
 * Корень репозитория и весь домашний каталог: поиск по ним дороже выгоды. Подкаталог (`~/p`,
 * `/home/denis/p`) в список не входит — там поиск законный, и правило не должно его запрещать.
 */
const BROAD_PATHS = [".", "./", "~", "~/", "$HOME", "${HOME}", "/home/denis", "/home/denis/"];

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
 * Слова сегмента: кавычки снимаются, перенаправления остаются отдельными словами.
 *
 * @param {string} segment
 * @returns {string[]}
 */
function words(segment) {
	const out = [];
	const re = /'([^']*)'|"([^"]*)"|(\S+)/g;
	let match;
	while ((match = re.exec(segment)) !== null) {
		out.push(match[1] ?? match[2] ?? match[3]);
	}
	return out;
}

/** Флаг, а не операнд: `-n`, `-rn`, `--quiet`; одинокий `-` — stdin, а не флаг. */
function isFlag(token) {
	return token.startsWith("-") && token !== "-";
}

/**
 * Что лежит по пути: `{ isFile, size }`, либо `null` — путь не проверен (относительный, нет такого).
 *
 * @param {string} path
 * @returns {{ isFile: boolean, size: number } | null}
 */
function probeFile(path) {
	try {
		const stat = statSync(path);
		return { isFile: stat.isFile(), size: stat.size };
	} catch {
		return null;
	}
}

/**
 * Файл читается только через `read`: размер не доказан большим (или не проверен вовсе).
 *
 * @param {string} path
 * @returns {boolean}
 */
function readsSmallFile(path) {
	const probe = probeFile(path);
	return probe === null || probe.size <= READ_LIMIT_BYTES;
}

/** Операнды сегмента: без флагов, без heredoc-меток и перенаправлений. */
function operands(args) {
	return args.filter((token) => !isFlag(token) && !token.startsWith("<") && !token.includes(">"));
}

/**
 * Сколько строк файла сторож отдаёт вместо запрошенного чтения (#16110).
 *
 * Отказ без содержимого стоил хода на каждой сессии (#16074 — 3, #16048 — 7, #16110 — 6–7): агент
 * повторял ту же цель законным инструментом. Возврат самого содержимого в тексте отказа делает отказ
 * бесплатным, а граница держит разговор коротким — столько же вернул бы `read` с `limit`.
 */
const EXCERPT_MAX_LINES = 200;
const EXCERPT_MAX_MATCHES = 50;

/**
 * Строки файла с номерами: `cat` — с начала, `sed -n 'A,Bp'` — запрошенный диапазон.
 *
 * @param {string} path
 * @param {number} from с 1
 * @param {number} to 0 с 1, включительно
 * @returns {string} пустая строка — файл не прочитан
 */
function linesExcerpt(path, from, to) {
	try {
		const all = readFileSync(path, "utf8").split("\n");
		const start = Math.max(1, from);
		const end = Math.min(to, all.length, start + EXCERPT_MAX_LINES - 1);
		if (end < start) return "";
		const lines = [];
		for (let n = start; n <= end; n += 1) {
			lines.push(`${String(n).padStart(6, " ")}\t${all[n - 1] ?? ""}`);
		}
		if (end < all.length) lines.push(`… строки ${end + 1}–${all.length} не показаны: их отдаст read с offset=${end + 1}`);
		return lines.join("\n");
	} catch {
		return "";
	}
}

/**
 * Совпадения `grep -n <шаблон> <файл>` с номерами строк.
 *
 * Шаблон берётся как регулярное выражение (grep по умолчанию BRE, JS — ERE: для конструкций вроде `\(`
 * они расходятся, для обычных слов и путей — нет). Не разобранный как регулярка шаблон
 * ищется подстрокой — лучше грубый ответ, чем пустой.
 *
 * @param {string} path
 * @param {string} pattern
 * @returns {string}
 */
function grepExcerpt(path, pattern) {
	let test;
	try {
		const re = new RegExp(pattern);
		test = (line) => re.test(line);
	} catch {
		test = (line) => line.includes(pattern);
	}
	try {
		const all = readFileSync(path, "utf8").split("\n");
		const hits = [];
		for (let i = 0; i < all.length; i += 1) {
			if (test(all[i])) hits.push(`${String(i + 1).padStart(6, " ")}\t${all[i]}`);
			if (hits.length > EXCERPT_MAX_MATCHES) break;
		}
		if (hits.length === 0) return `совпадений «${pattern}» в файле нет`;
		const shown = hits.slice(0, EXCERPT_MAX_MATCHES);
		if (hits.length > EXCERPT_MAX_MATCHES) shown.push(`… совпадений больше ${EXCERPT_MAX_MATCHES}: сузьте шаблон или берите ffgrep с limit`);
		return shown.join("\n");
	} catch {
		return "";
	}
}

/**
 * Правило чтения: `sed -n`, `cat <файл>`, `grep -n <файл>` по файлу до 50 КБ и `grep -r` по дому.
 *
 * @param {string} segment
 * @returns {{ allowed: boolean, reason: string, hint: string, excerpt?: string } | null}
 */
function readingVerdict(segment) {
	const parts = words(segment);
	const command = parts[0];
	if (command !== "sed" && command !== "cat" && command !== "grep") return null;

	const args = parts.slice(1);
	const hintRead = "Чтение файла — `read` с `offset` и `limit` (нумерация строк, обрезка вывода, дифф), поиск по содержимому — `ffgrep`, поиск по пути — `fffind`. Осознанно — PI_CALL_GUARD_ALLOW=1.";

	if (command === "sed") {
		const quiet = args.some((token) => token === "-n" || token === "--quiet" || token === "--silent"
			|| /^-[a-zA-Z]*n[a-zA-Z]*$/.test(token));
		if (!quiet) return null;
		const script = args.find((token) => SED_PRINT_RANGE.test(token));
		if (script === undefined) return null;
		const file = operands(args.slice(args.indexOf(script) + 1))[0];
		if (file === undefined || file === "-" || !readsSmallFile(file)) return null;
		const [from, to] = script.slice(0, -1).split(",").map((value) => Number.parseInt(value, 10));
		return {
			allowed: false,
			reason: "`sed -n 'N,Mp' <файл>` — чтение файла через bash; преимуществ перед `read` у него нет.",
			hint: hintRead,
			excerpt: linesExcerpt(file, from, Number.isFinite(to) ? to : from),
		};
	}

	if (command === "cat") {
		// `cat > файл`, `cat >> журнал`, `cat <<EOF` — это запись и heredoc, а не чтение: их правило
		// не трогает (иначе блокировался бы самый обычный способ создать временный файл).
		if (args.some((token) => token.includes(">") || token.startsWith("<"))) return null;
		const files = operands(args);
		if (files.length === 0 || files.includes("-")) return null;
		if (!files.some((file) => readsSmallFile(file))) return null;
		// Несколько файлов сторож не отдаёт: `cat a b` — это склейка, и порядок в ней важен для
		// читающего; без содержимого остаётся обычный отказ.
		return {
			allowed: false,
			reason: "`cat <файл>` — то же чтение, что и `read`, но без номеров строк и без номера области.",
			hint: hintRead,
			excerpt: files.length === 1 ? linesExcerpt(files[0], 1, EXCERPT_MAX_LINES) : "",
		};
	}

	const recursive = args.some((token) => token === "--recursive" || token === "--dereference-recursive"
		|| /^-[a-zA-Z]*[rR][a-zA-Z]*$/.test(token));
	const positional = operands(args);
	if (recursive) {
		const paths = positional.slice(1);
		const broad = paths.some((path) => BROAD_PATHS.includes(path) || path === "/home/denis/.");
		if (!broad) return null;
		return {
			allowed: false,
			reason: "`grep -r` по домашнему каталогу или корню репозитория: два таких вызова в одной сессии умерли по таймауту (60 с и 10 с).",
			hint: "Сужьте путь или берите `ffgrep pattern='…' path='…' exclude='…' limit=20` (он сразу без зеркал); для особого случая — `rg` с `--glob '!…'`. Осознанно — PI_CALL_GUARD_ALLOW=1.",
		};
	}

	const numbered = args.some((token) => token === "--line-number" || /^-[a-zA-Z]*n[a-zA-Z]*$/.test(token));
	const files = positional.slice(1);
	// `grep -n шаблон -` читает stdin: файла нет, и правило чтения файла к нему не относится.
	if (!numbered || files.length === 0 || files.includes("-")) return null;
	const suspicious = files.some((file) => {
		const probe = probeFile(file);
		return probe !== null && !probe.isFile ? false : readsSmallFile(file);
	});
	if (!suspicious) return null;
	// Шаблон — первый операнд, файлы — остальные; для нескольких файлов содержимое не отдаётся, как и
	// у `cat`: смешать их вывод значило бы соврать о том, откуда строка.
	return {
		allowed: false,
		reason: "`grep -n <файл>` — поиск по файлу через bash; `ffgrep` учитывает `.gitignore` и держит вывод в `limit`.",
		hint: hintRead,
		excerpt: files.length === 1 ? grepExcerpt(files[0], positional[0] ?? "") : "",
	};
}

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
 * Первая ступень конвейера: текст до первого `|` вне кавычек. `grep -n 'a|b' файл` — один сегмент,
 * а не две ступени; без этого разбор кавычек съел бы шаблон и заблокировал чтение зря.
 *
 * @param {string} segment
 * @returns {string}
 */
export function firstPipelineStage(segment) {
	let quote = null;
	for (let i = 0; i < segment.length; i += 1) {
		const char = segment[i];
		if (quote !== null) {
			if (char === quote) quote = null;
			continue;
		}
		if (char === "'" || char === '"') {
			quote = char;
			continue;
		}
		if (char === "|") return segment.slice(0, i);
	}
	return segment;
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
		// Чтение проверяется и в конвейере, по первой ступени: `cat файл | head` — тот же `cat`, и
		// именно `| head` был самым естественным обходом правила (замер ревью: 26 вызовов `sed -n`,
		// ради которых правило написано, проходили ровно так). Правило 2 наоборот требует конвейер
		// как признак фильтра, поэтому ниже сегменты с `|` по-прежнему пропускаются.
		const reading = readingVerdict(unwrapped(firstPipelineStage(raw)));
		if (reading !== null) return reading;

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

	const lines = [`Call Guard blocked: ${verdict.reason ?? "вызов без цели"}`];
	if (verdict.excerpt) {
		// Содержимое отдаётся до подсказки о законном инструменте: агенту нужен ответ, а не нотация.
		// Повторный вызов не нужен — это и есть цель правки #16110.
		lines.push(
			"Запрошенное содержимое — здесь, повторный вызов не нужен:",
			verdict.excerpt,
			"Дальше этот файл читайте `read` (offset/limit, нумерация и дифф) или `ffgrep`: сторож отдаёт только первую область, остальное — нет."
		);
	}
	if (verdict.hint) lines.push(verdict.hint);
	return { block: true, reason: lines.join("\n") };
}
