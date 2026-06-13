import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

type SafetyConfig = {
	enabled: boolean;
};

type Risk = {
	action: string;
	command?: string;
	reason?: string;
	severity: "destructive" | "risky";
};

const CONFIG_PATH = join(homedir(), ".pi", "agent", "safety-guard.json");

const DEFAULT_CONFIG: SafetyConfig = { enabled: true };

function loadConfig(): SafetyConfig {
	try {
		const parsed = JSON.parse(readFileSync(CONFIG_PATH, "utf8")) as Partial<SafetyConfig>;
		return { ...DEFAULT_CONFIG, ...parsed };
	} catch {
		return DEFAULT_CONFIG;
	}
}

function saveConfig(config: SafetyConfig) {
	mkdirSync(dirname(CONFIG_PATH), { recursive: true });
	writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2) + "\n", "utf8");
}

function formatRisk(risk: Risk): string {
	const lines = [`ACTION: ${risk.action}`];
	if (risk.command) lines.push(`COMMAND: \`${risk.command}\``);
	if (risk.reason) lines.push(`REASON: ${risk.reason}`);
	return lines.join("\n");
}

function shellWords(command: string): string[] {
	return command
		.split(/\s+/)
		.map((part) => part.trim())
		.filter(Boolean);
}

function classifyBash(command: string): Risk | undefined {
	const normalized = command.replace(/\\\n/g, " ").replace(/\s+/g, " ").trim();
	const words = shellWords(normalized);

	if (/\bgit\s+push\b[\s\S]*(--force|-f|--force-with-lease)\b/i.test(normalized)) {
		return {
			action: "Force push git history",
			command,
			reason: "Force pushes can overwrite remote history for other collaborators.",
			severity: "destructive",
		};
	}

	if (/\bgit\s+commit\b[\s\S]*(--amend)\b/i.test(normalized)) {
		return {
			action: "Amend the latest git commit",
			command,
			reason: "Amending rewrites local commit history.",
			severity: "destructive",
		};
	}

	if (/\bgit\s+reset\b[\s\S]*(--hard)\b/i.test(normalized)) {
		return {
			action: "Hard reset git working tree",
			command,
			reason: "A hard reset discards uncommitted local changes.",
			severity: "destructive",
		};
	}

	if (/\bgit\s+(rebase|filter-branch)\b/i.test(normalized)) {
		return {
			action: "Rewrite git history",
			command,
			reason: "This git operation can rewrite commit history.",
			severity: "destructive",
		};
	}

	if (/\bgit\s+(branch|tag)\b[\s\S]*\s-d\b|\bgit\s+(branch|tag)\b[\s\S]*\s-D\b|\bgit\s+push\b[\s\S]*(:refs\/|--delete)\b/i.test(normalized)) {
		return {
			action: "Delete git branch or tag",
			command,
			reason: "Deleting refs can remove useful recovery points.",
			severity: "destructive",
		};
	}

	if (/\brm\b[\s\S]*(-r|-R|-f|--recursive|--force)\b/i.test(normalized) || /\bfind\b[\s\S]*\s-delete\b/i.test(normalized)) {
		return {
			action: "Delete files or directories",
			command,
			reason: "The command removes data from the filesystem.",
			severity: "destructive",
		};
	}

	if (/\b(truncate|shred)\b/i.test(normalized) || />\s*[^&\s][^\n]*(\.env|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|\.json|\.ts|\.tsx|\.js|\.jsx|\.py|\.rs|\.go)\b/i.test(normalized)) {
		return {
			action: "Overwrite or erase file contents",
			command,
			reason: "The command may replace existing file contents.",
			severity: "destructive",
		};
	}

	if (/\b(sudo\s+)?(apt|apt-get|dnf|yum|pacman|brew)\s+(remove|purge|uninstall|autoremove)\b/i.test(normalized)) {
		return {
			action: "Remove system packages",
			command,
			reason: "Package removal can change the host system outside the project.",
			severity: "destructive",
		};
	}

	if (/\b(sudo\s+)?(systemctl|service)\s+(stop|disable|restart)\b/i.test(normalized)) {
		return {
			action: "Change system service state",
			command,
			reason: "Service changes can disrupt running system processes.",
			severity: "risky",
		};
	}

	if (words.includes("sudo")) {
		return {
			action: "Run a privileged system command",
			command,
			reason: "sudo commands can modify system-level state.",
			severity: "risky",
		};
	}

	return undefined;
}

function classifyFileTool(toolName: string, input: Record<string, unknown>, inGitRepo: boolean): Risk | undefined {
	const path = typeof input.path === "string" ? input.path : undefined;
	if (!path) return undefined;

	if (/(^|\/)\.env($|\.)|(^|\/)\.git(\/|$)|(^|\/)node_modules(\/|$)/.test(path)) {
		return {
			action: `Modify protected path ${path}`,
			reason: "Protected paths often contain secrets, git internals, or dependency artifacts.",
			severity: "destructive",
		};
	}

	if (inGitRepo) return undefined;

	if (toolName === "write" && existsSync(path)) {
		return {
			action: `Overwrite existing file ${path}`,
			reason: "This file is not protected by a detected git recovery point.",
			severity: "destructive",
		};
	}

	if (toolName === "edit") {
		const edits = Array.isArray(input.edits) ? input.edits.length : 1;
		if (edits >= 3) {
			return {
				action: `Apply ${edits} edits to ${path}`,
				reason: "Large-scale edits outside a detected git repo are harder to recover.",
				severity: "risky",
			};
		}
	}

	return undefined;
}

function lastUserText(ctx: ExtensionContext): string {
	const entries = ctx.sessionManager.getEntries();
	for (let i = entries.length - 1; i >= 0; i--) {
		const entry = entries[i] as any;
		const message = entry.type === "message" ? entry.message : undefined;
		if (message?.role !== "user") continue;
		const content = message.content;
		if (typeof content === "string") return content;
		if (Array.isArray(content)) {
			return content
				.map((part) => (part?.type === "text" && typeof part.text === "string" ? part.text : ""))
				.join("\n")
				.trim();
		}
	}
	return "";
}

function userExplicitlyRequestedRisk(userText: string, risk: Risk): boolean {
	const text = userText.toLowerCase();
	if (!text) return false;

	const explicitDestructiveVerb = /\b(delete|remove|erase|wipe|purge|destroy|overwrite|replace|reset hard|hard reset|amend|rebase|force push|force-push|drop|truncate|shred|uninstall|disable|stop|restart)\b/i.test(text);
	if (!explicitDestructiveVerb) return false;

	if (risk.command && text.includes(risk.command.toLowerCase())) return true;

	const action = risk.action.toLowerCase();
	return (
		(action.includes("delete") && /\b(delete|remove|erase|wipe|purge)\b/i.test(text)) ||
		(action.includes("overwrite") && /\b(overwrite|replace)\b/i.test(text)) ||
		(action.includes("force push") && /\b(force push|force-push)\b/i.test(text)) ||
		(action.includes("amend") && /\bamend\b/i.test(text)) ||
		(action.includes("reset") && /\b(reset hard|hard reset)\b/i.test(text)) ||
		(action.includes("history") && /\b(rebase|rewrite history|amend)\b/i.test(text)) ||
		(action.includes("system") && /\b(sudo|system|service|package|uninstall|remove)\b/i.test(text))
	);
}

async function isInsideGitRepo(pi: ExtensionAPI): Promise<boolean> {
	try {
		const result = await pi.exec("git", ["rev-parse", "--is-inside-work-tree"]);
		return result.code === 0 && result.stdout.trim() === "true";
	} catch {
		return false;
	}
}

async function shouldAllowRisk(risk: Risk, ctx: ExtensionContext): Promise<boolean> {
	if (!ctx.hasUI) return false;

	const choice = await ctx.ui.select(`${formatRisk(risk)}\n\nAllow this action?`, [
		"Allow once",
		"Block",
	]);

	return choice === "Allow once";
}

export default function safetyGuard(pi: ExtensionAPI) {
	let config = loadConfig();

	function setEnabled(enabled: boolean) {
		config = { ...config, enabled };
		saveConfig(config);
	}

	function safetyPrompt(): string {
		return `\n\nSafety Guard is enabled. Before performing a destructive action that the user did not explicitly request, ask for permission with ask_user_question and use this template in the option/description text:\nACTION: one-line short but understandable description\nCOMMAND (if applicable): \`command here\`\nREASON (if applicable): one-line reason\nDo not over-ask: normal recoverable edits in git-tracked projects do not need confirmation. Destructive actions include deletes, large-scale unrecoverable modifications, destructive system changes, git history rewrites/amends, and force pushes. Coalesce related confirmations into as few questions as possible.`;
	}

	pi.registerCommand("safety", {
		description: "Manage Safety Guard: /safety enable|disable|status",
		handler: async (args, ctx) => {
			const subcommand = args.trim().toLowerCase();
			if (subcommand === "enable") {
				setEnabled(true);
				ctx.ui.setStatus("safety", "safety: on");
				ctx.ui.notify("Safety Guard enabled", "info");
				return;
			}
			if (subcommand === "disable") {
				setEnabled(false);
				ctx.ui.setStatus("safety", "safety: off");
				ctx.ui.notify("Safety Guard disabled", "warning");
				return;
			}
			if (subcommand === "status" || subcommand === "") {
				ctx.ui.notify(`Safety Guard is ${config.enabled ? "enabled" : "disabled"}`, config.enabled ? "info" : "warning");
				return;
			}
			ctx.ui.notify("Usage: /safety enable | /safety disable | /safety status", "warning");
		},
	});

	pi.registerCommand("permissions", {
		description: "Alias for Safety Guard: /permissions enable|disable|status",
		handler: async (args, ctx) => {
			const subcommand = args.trim().toLowerCase();
			if (subcommand === "enable") {
				setEnabled(true);
				ctx.ui.setStatus("safety", "safety: on");
				ctx.ui.notify("Safety Guard enabled", "info");
				return;
			}
			if (subcommand === "disable") {
				setEnabled(false);
				ctx.ui.setStatus("safety", "safety: off");
				ctx.ui.notify("Safety Guard disabled", "warning");
				return;
			}
			if (subcommand === "status" || subcommand === "") {
				ctx.ui.notify(`Safety Guard is ${config.enabled ? "enabled" : "disabled"}`, config.enabled ? "info" : "warning");
				return;
			}
			ctx.ui.notify("Usage: /permissions enable | /permissions disable | /permissions status", "warning");
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		if (ctx.hasUI) ctx.ui.setStatus("safety", `safety: ${config.enabled ? "on" : "off"}`);
	});

	pi.on("before_agent_start", async (event) => {
		if (!config.enabled) return undefined;
		return { systemPrompt: event.systemPrompt + safetyPrompt() };
	});

	pi.on("tool_call", async (event, ctx) => {
		if (!config.enabled) return undefined;

		let risk: Risk | undefined;
		if (event.toolName === "bash") {
			const command = (event.input as Record<string, unknown>).command;
			if (typeof command === "string") risk = classifyBash(command);
		} else if (event.toolName === "write" || event.toolName === "edit") {
			const inGitRepo = await isInsideGitRepo(pi);
			risk = classifyFileTool(event.toolName, event.input as Record<string, unknown>, inGitRepo);
		} else if (event.toolName === "ctx_purge") {
			risk = {
				action: "Purge context-mode knowledge base",
				reason: "Purging permanently deletes indexed context and session-memory data.",
				severity: "destructive",
			};
		}

		if (!risk) return undefined;

		if (userExplicitlyRequestedRisk(lastUserText(ctx), risk)) {
			return undefined;
		}

		const allowed = await shouldAllowRisk(risk, ctx);
		if (!allowed) {
			return { block: true, reason: `Safety Guard blocked action.\n${formatRisk(risk)}` };
		}

		return undefined;
	});
}
