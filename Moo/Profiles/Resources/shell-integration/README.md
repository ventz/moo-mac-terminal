# Moo shell integration

Moo loads this integration automatically for interactive Zsh, Fish,
Nushell, Elvish, and supported Bash sessions. The scripts report prompt and
command boundaries with OSC 133. They also report the current directory with
OSC 7 and can update the terminal title and cursor.

Every child process receives `MOO_RESOURCES_DIR`. Users can use this
variable to load the bundled scripts manually or to locate related files.

## Bash

Add this code at the start of `.bashrc` when automatic injection is not
available. The `/bin/bash` version from macOS needs manual injection.

```bash
if [ -n "${MOO_RESOURCES_DIR}" ]; then
    builtin source "${MOO_RESOURCES_DIR}/shell-integration/bash/moo.bash"
fi
```

## Zsh

```zsh
if [[ -n $MOO_RESOURCES_DIR ]]; then
    source "$MOO_RESOURCES_DIR/shell-integration/zsh/moo-integration"
fi
```

Zsh 5.1 or later is required.

## Nushell

```nushell
source $MOO_RESOURCES_DIR/shell-integration/nushell/vendor/autoload/moo.nu
use moo *
```

## Elvish

Moo adds the shell-integration directory to `XDG_DATA_DIRS`. Add this code
to the Elvish configuration to load the module automatically:

```elvish
if (eq $E:TERM_PROGRAM "moo") {
  try { use moo-integration } catch { }
}
```

## Source and licenses

These scripts are adapted from Ghostty's shell integration. The Bash and Zsh
files that contain GPL notices remain under GPLv3. `bash-preexec.sh` keeps its
upstream license and attribution in the file. The bundled `LICENSE` contains
the Moo MIT license and the complete Ghostty MIT license text.
