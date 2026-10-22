# Prompt Paws plugin

Connects Claude Code to [Prompt Paws](https://github.com/biswajitdasb4-oss/prompt-paws), a 3D desktop panda for macOS. The panda's bubble shows when a session is working, needs you, or waits for your next prompt, and one click on the panda brings you to that session's Terminal tab.

Install (Claude Code 2.1.275 or later):

    /plugin install prompt-paws --marketplace biswajitdasb4-oss/prompt-paws

This plugin only adds hooks that write small status files to `~/.promptpaws/`; the Prompt Paws app (installed separately, see the main README) reads them. Nothing leaves your Mac.
