;;; my-ai-agent-shell.el --- agent-shell (ACP agents: Claude Code, Codex, Gemini, ...)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
;;
;; Agents need their ACP adapter on PATH, e.g.
;;   npm i -g @agentclientprotocol/claude-agent-acp   (Claude Code)
;;   npm i -g @zed-industries/codex-acp               (Codex)
;; `agent-shell' is project-aware: shells started inside a project use its
;; root as cwd, and tabspaces keeps the shell buffer in that project's workspace.

(use-package agent-shell
  :commands (agent-shell agent-shell-new-shell agent-shell-toggle
             agent-shell-switch-buffer agent-shell-interrupt agent-shell-send-file
             agent-shell-set-session-model agent-shell-set-session-mode
             agent-shell-anthropic-start-claude-code
             agent-shell-openai-start-codex
             agent-shell-google-start-gemini)
  :custom
  ;; Claude subscription login. For an API key use:
  ;; (agent-shell-anthropic-make-authentication :api-key (lambda () (getenv "ANTHROPIC_API_KEY")))
  (agent-shell-anthropic-authentication
   (agent-shell-anthropic-make-authentication :login t))
  ;; nil: always ask which agent to start (set to e.g. 'claude-code to skip the picker)
  (agent-shell-preferred-agent-config nil)
  (agent-shell-show-welcome-message nil))

(my/leader
  "aa" '(agent-shell :wk "agent shell (project)")
  "an" '(agent-shell-new-shell :wk "new shell")
  "at" '(agent-shell-toggle :wk "toggle")
  "ac" '(agent-shell-anthropic-start-claude-code :wk "claude code")
  "ax" '(agent-shell-openai-start-codex :wk "codex")
  "ag" '(agent-shell-google-start-gemini :wk "gemini")
  "af" '(agent-shell-send-file :wk "send file")
  "ab" '(agent-shell-switch-buffer :wk "switch shell")
  "ai" '(agent-shell-interrupt :wk "interrupt")
  "am" '(agent-shell-set-session-model :wk "model")
  "as" '(agent-shell-set-session-mode :wk "session mode"))

(provide 'my-ai-agent-shell)
