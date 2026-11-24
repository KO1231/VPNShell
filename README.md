# VPNShell

VPNShell is a tool for macOS that builds a **shell in which all traffic is guaranteed to go through your NordVPN Dedicated IP** (WireGuard / NordLynx).
Because the shell runs without affecting the rest of your machine's traffic (your browser, your everyday `ssh` and `git`), you can keep your machine connected to a regular VPN server with the NordVPN app while only a specific shell communicates through your Dedicated IP.

Each shell is a disposable container created every time you open it, and it shares the network of a [gluetun](https://github.com/passteque/gluetun) container. Even when the VPN drops, when gluetun is recreated, or when the configuration is wrong, the shell is designed so that it cannot communicate directly over your machine's network (fail-closed).

```
$ vpnsh
 VPN 203.0.113.10  ~ $ curl -s https://api.ipify.org
203.0.113.10
```

## Features

- **Fail-closed design** — the firewall rules, routing, DNS, IPv6 and the integrity of gluetun are verified on every start, and the public IP is checked against your Dedicated IP using multiple check services run by different operators
- **The private key is stored in the macOS Keychain** — the WireGuard private key is never written to a file, and macOS asks for confirmation each time it is used
- **Use SSH without handing over your keys (`--ssh`)** — SSH keys are placed in a dedicated `ssh-agent`, a confirmation dialog appears every time the shell uses one, and they can be used only with the servers you registered. Your machine's `ssh-agent` and `~/.ssh` are never touched
- **Work on your local projects** — mount the current directory read-only (`-m`) or read-write (`--mount-cwd-rw`)
- **Hardened, disposable shells** — each shell is disposable and has no permission to modify system directories; capabilities, setuid programs and `ptrace` are all forbidden, so the design is robust against a shell takeover

## Requirements

- macOS
- [OrbStack](https://orbstack.dev/) 2.2.4 or later
- A NordVPN subscription with the **Dedicated IP** add-on
- zsh (used by `vpnsh install-shell` and for completion)

## Installation

1. Clone this repository (you can put it anywhere).
   ```zsh
   git clone <URL of this repository> ~/VPNShell
   ```

2. Add `vpnsh` to your `PATH` and enable completion (it shows the changes and asks for confirmation before editing `~/.zshrc`)
   ```zsh
   ~/VPNShell/bin/vpnsh install-shell
   ```
   When it is done, open a new terminal.

3. Download the WireGuard configuration file for your Dedicated IP
    - Sign in to [Nord Account](https://my.nordaccount.com/), open **NordVPN → Dedicated IP**, choose **WireGuard** for manual setup, and download the `.conf` file
    - Note down the Dedicated IP address shown on the page

4. Import the file
   ```zsh
   vpnsh setup --import ~/Downloads/<file name>.conf
   ```
   This stores the private key in the Keychain, builds the container image and starts gluetun. Finally, it asks you to enter your Dedicated IP so that it can verify it against the public IP it observes.

5. Delete the `.conf` file. It contains the private key in plain text, and NordVPN Dedicated IP keys **cannot be revoked**. The only way to recover from a leak is to change your Dedicated IP.

## Usage

```zsh
vpnsh                         # open a shell that uses your Dedicated IP (closing it with `exit` discards it)
vpnsh run curl -s https://api.ipify.org    # run a single command
vpnsh -m                      # mount the current directory at /work (read-only)
vpnsh --mount-cwd-rw          # mount it read-write
vpnsh status                  # show the state of gluetun and the open shells
vpnsh check --full            # run the pre-start checks and active leak probes
vpnsh doctor                  # inspect your settings and state at once, without any network access
vpnsh help                    # list the commands
```

For security, mounting is restricted to directories under `mount-root` (`~/Projects` by default). You can change it with `vpnsh config set mount-root <directory>`.

### SSH

```zsh
vpnsh ssh host add myserver   # register a Host from ~/.ssh/config (verifies the host key and loads the key)
vpnsh --ssh                   # open a shell where `ssh myserver` and `git clone myserver:repo.git` work
vpnsh ssh list -a             # show the registered servers and the loaded keys
```

## Development

```zsh
tests/unit-test.sh       # unit tests (no Docker)
tests/mount-test.sh      # tests for the mount safeguards (no Docker)
tests/firewall-test.sh   # tests for the firewall rules and pre-start checks (uses a disposable gluetun with a non-existent endpoint)
tests/ssh-test.sh        # tests for the SSH relay, confirmation and key restrictions (uses disposable keys and sshd)
tests/image-test.sh      # tests that the work image is hardened (no network; also runs in CI)
scripts/update-pins --check   # check whether newer versions of the pinned images exist
```
