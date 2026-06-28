# OS/Linux Assistant

TODO: this is a crude capture of ideas, needs to be polished and brainstormed.

A generic assistant is a very hard thing to do:

- Security: Trifecta bites
- Complexity: all gems combined; MCPs for virtually any task available

I propose to start smaller: an OS/Linux assistant.

- RW Access to the entire filesystem, no sandbox (the purpose is to control the host OS)
- Initially, no internet access: this breaks the trifecta leg, allowing us
  to postpone the trifecta tackling. Even with no internet access, the OS helper
  is still very useful since it can still answer questions about the local OS,
  by knowing the environment, being trained on Linux+bash and being able to read man pages.
- Local LLMs; targetting Qwen 3.6 35B A3B running locally in llama-server
- If sudo is needed, user must run the command.

Use-cases and example prompts:
- TODO something the user would type into MacOS spotlight and expect a decent answer
  - Find file xyz
  - Can also open/edit file via `xdg-open`
  - Find in files? Via tracker or some other indexer, something that's baked in Ubuntu by default?
  - No find in e-mails or apps unless the tracker/indexer supports this flawlessly
  - Not an app launcher... well, technically, why not. It will be slower than the system launcher, but if the user is okay with that, why not?
  - network-manager integration? E.g. "diagnose internet access"
  - TODO: find a good set of common OS-related tasks the user generally need
  - systemd services?
- Help with GUI configuration - e.g. how to reverse trackpad scroll direction.
  - Initially GNOME only?
- Help with diagnosing kernel/system errors
  - Reading kernel log; can the error be resolved by using local documentation only?
  - systemd - detecting errorred services and diagnosing their logs?
  - OS health: detecting high resource usage, e.g. running out of disk space
  - searching internet for errors - requires internet access, deferred.
- Helping evaluate right apt/snap package when a functionality is needed
  - snap: prefer recognized publishers only, e.g. Canonical (e.g. Thunderbird or Steam snap)

How will the LLM learn about the OS?
- Only Linux supported
  - Initially only Ubuntu supported. (Debian also?)
  - `inxi -e` / or reading stuff from `/proc` - but that may require training + knowledge.
- /etc/lsb-release should be baked in system prompt, along with the home path, current date and time
  - Include XDG conventions in the system prompt?
  - quick intro on apt? List installed apps, install app, ...
  - location of system logs? quick training on the Linux filesystem structure?
  - location of local offline Ubuntu docs (are they available by default)? Perhaps indexed and searchable, vectordb style?
  - quick intro on man pages? Or is it too basic and we can generally expect LLMs to know this?

Available tools:
- bash, with simple confirmer (confirm every command)
- workspace tools (read, edit, glob, grep) allowing unrestricted access to the entire disk,
  including `/etc` and sensitive files in home, e.g. `~/.ssh`
- Memory of previous conversations or facts about this particular computer.
  - e.g. the assistant remembers where the user keeps music, work folders, documents, whether the documents are synced (if yes, which sync system is used, Dropbox, syncthing, ...)

Security:
- We trust local files, man pages and local documentation (e.g. Ubuntu docs) for no prompt injection
- No internet access, severing trifecta leg.

## Future ideas (deferred for now)

- Internet access, possibly via an investigator subagent
  - Beware of trifecta.

