// @file: write-guard-core.mjs
// @description: Решение «пропустить / заблокировать» для перезаписи существующего файла инструментом write.
// @dependencies: нет
// @created: 2026-11-19
//
// Вынесено из write-guard.ts, чтобы правило проверялось тестом без запуска Pi:
// `node --test tests/write-guard.test.mjs`.
//
// Зачем (#15739 п.5): `write` перезаписывает файл целиком. В сессии #15719 одна запись заменила
// `ParityFundingRate.php` словом `placeholder`, и восстановление шло только через
// `git checkout --`. Пять плейсхолдерных записей и пять падений `edit` на неоднозначном `oldText`
// стоили около десяти лишних вызовов и одного почти потерянного файла.
//
// Правило узкое намеренно — блокируется ровно один случай:
//   * путь существует и это файл (не каталог, не симлинк),
//   * он отслеживается git (откат возможен, но цель правки очевидно не та),
//   * он больше 1 КБ (мелкие файлы — это не «код проекта»: конфиг на десять строк переписывают целиком),
//   * новое содержимое короче 20 % старого ИЛИ меньше 200 байт.
//
// Так выглядит запись-плейсхолдер и запись «одна строка вместо модуля». Новая версия того же файла,
// сокращённая вдвое, проходит: это обычная правка, просто большая. Осознанный обход —
// PI_WRITE_GUARD_ALLOW=1.

/** Файл меньше этого — не код проекта, полная перезапись нормальна. */
export const MIN_TRACKED_BYTES = 1024;

/** Новое содержимое короче 20 % старого — почти наверняка потеря, а не правка. */
export const MIN_KEEP_RATIO = 0.2;

/** И жёсткий пол: содержимое короче 200 байт в крупном файле — плейсхолдер. */
export const ABSOLUTE_FLOOR_BYTES = 200;

/**
 * @param {object} input
 * @param {number} input.oldBytes — размер файла на диске до записи
 * @param {number} input.newBytes — размер нового содержимого
 * @param {boolean} input.tracked — файл отслеживается git
 * @param {boolean} [input.allow] — осознанный обход
 * @returns {{ allowed: boolean, reason?: string, hint?: string }}
 */
export function classifyShrink(input) {
	if (input.allow) return { allowed: true };
	if (!input.tracked) return { allowed: true };
	if (input.oldBytes <= MIN_TRACKED_BYTES) return { allowed: true };

	const tooShort = input.newBytes < ABSOLUTE_FLOOR_BYTES;
	const tooMuchLost = input.newBytes < input.oldBytes * MIN_KEEP_RATIO;
	if (!tooShort && !tooMuchLost) return { allowed: true };

	return {
		allowed: false,
		reason: `write затирает отслеживаемый файл: было ${input.oldBytes} Б, станет ${input.newBytes} Б.`,
		hint: "Для правки существующего файла — `edit` (несколько oldText за вызов); полная перезапись крупного файла почти всегда означает, что путь или содержимое перепутаны. Осознанно — PI_WRITE_GUARD_ALLOW=1.",
	};
}

/**
 * @param {{ allowed: boolean, reason?: string, hint?: string }} verdict
 */
export function toToolCallResult(verdict) {
	if (verdict.allowed) return undefined;

	const lines = [`Write Guard blocked.\n${verdict.reason ?? "перезапись файла"}`];
	if (verdict.hint) lines.push(verdict.hint);
	return { block: true, reason: lines.join("\n") };
}
