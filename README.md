```
    _   __     __  ____  _
   / | / /__  / /_/ __ \(_)___  ____ _
  /  |/ / _ \/ __/ /_/ / / __ \/ __ `/
 / /|  /  __/ /_/ _, _/ / / / / /_/ /
/_/ |_/\___/\__/_/ |_/_/_/ /_/\__, /
                             /____/
```

> *"One NetRing to rule them all"*

# NetRing

NetRing is a modular command line framework for PowerShell that bundles a collection of network tools into one interactive toolkit.

> **Status:** early development. The framework and its modules are being built step by step.

---

## Table of contents

- [Key features](#key-features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Getting started](#getting-started)
- [Usage](#usage)
- [Project structure](#project-structure)
- [Writing a module](#writing-a-module)
- [Roadmap](#roadmap)

---

## Key features

- **Interactive menus.** Pick a category and a tool by typing its number
- **Aliases for speed.** Type `ALIAS PARAMETER PARAMETER` instead of clicking through several menu levels.
- **Modular by design.** Every tool lives in its own module. A broken or missing module never takes down the framework or any other module.
- **Network focused.** The toolkit concentrates on network diagnostics, discovery and administration.
- **Pure PowerShell.** No external installer needed; NetRing runs from the PowerShell console you already use.

## How it works

NetRing has a small core and a set of independent modules.

| Component | Responsibility |
|-----------|----------------|
| **Core** | Shows the banner, builds the menus, parses aliases and loads the modules. |
| **Modules** | Each module contains one or more tools and registers its own menu entries and aliases with the core. |
| **Isolation layer** | Every module is loaded and executed inside its own error boundary. If a module fails to load or throws an error, NetRing reports it and keeps running. |

Because modules only talk to the core and never to each other directly, you can add, update or remove a module without touching the rest of the toolkit.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- Administrator rights may be needed for some network tools

## Getting started

```powershell
# Clone or download the repository
cd NetRing

# Start the toolkit
.\NetRing.ps1

# Or run one alias directly and return to PowerShell
.\NetRing.ps1 trace 8.8.8.8
```

If script execution is blocked on your system, allow it for the current session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Usage

### Menu mode

The main menu always shows the same categories in the same order, so the numbers never change when modules are added. Empty categories are shown in gray with `0 tools`.

| Nr | Category | Question it answers |
|----|----------|---------------------|
| 1 | This machine | How is my own computer configured? |
| 2 | Discovery | Who is on my network? |
| 3 | Connectivity | Can I reach a host, and along which path? |
| 4 | DNS | Does name resolution work? |
| 5 | Services | Which services run on a host? |
| 6 | Web | Is that website or certificate in order? |
| 7 | Calculators | Network math, no network needed |
| 8 | Security | Are there weak spots? |

The categories are defined in `Core/Categories.psd1`. Modules with an unknown category end up in an extra category `Other`.

After starting NetRing you see the main menu. Type a number and press Enter to go one level deeper. Use `0` (or `back`) to return to the previous menu. Several numbers on one line form a path from the main menu, so `3 1` always opens the first tool of Connectivity.


### Alias mode

Navigating with numbers is great for exploring but slow when you know exactly what you want. Every tool therefore also has an alias. Instead of typing

```
5 [Enter]  3 [Enter]  2 [Enter]  ...
```

you type the alias followed by its parameters on a single line:

```
netring> ALIAS PARAMETER PARAMETER
```

Parameters are positional in the order shown by `help <alias>`. Named parameters also work and can be mixed:

```
netring> trace 8.8.8.8 20
netring> trace 8.8.8.8 -Probes 1 -Resolve off
```

Required parameters you leave out are asked for interactively.

Built in commands:

| Command | Description |
|---------|-------------|
| `help` | Show general help. |
| `help <alias>` | Show help and parameters for a specific tool. |
| `aliases` | List all available aliases. |
| `modules` | List loaded modules and their status. |
| `menu` / Enter | Show the current menu again. |
| `back` / `0` | Return to the previous menu. |
| `reload` | Reload all modules without restarting. |
| `clear` | Clear the screen. |
| `exit` | Quit NetRing. |

## Project structure

```
NetRing/
├── NetRing.ps1               # Entry point
├── Core/                     # The core, never contains tool logic
│   ├── Categories.psd1       # Menu categories: order and names        
│   ├── Console.ps1           # Banner, colors, output helpers
│   ├── ModuleLoader.ps1      # Discovers, validates and loads modules
│   ├── AliasParser.ps1       # Tokenizer, argument binding, error boundary
│   └── Menu.ps1              # Menu engine, built in commands, shell loop
├── Modules/                  # One folder per module
│   ├── _Template/            # Starting point for a new module (ignored)
│   ├── AdapterControl/
│   ├── LanInfo/
│   ├── NetScan/
│   ├── PortScan/
│   ├── VisualTrace/
│   └── WebExplain/
│       ├── module.psd1       # Metadata: name, version, menu entries, aliases
│       └── module.psm1       # Tool logic
└── README.md
```

## Modules

| Module | Category | Alias | Description |
|--------|----------|-------|-------------|
| NetScan | Discovery | `scan [Subnet] [Timeout] [Resolve] [Ask]` | Who is on my network? Scans a subnet (`192.168.1.0/24`), a range (`192.168.1.100-200`) or one address. Pings every address in parallel and combines it with the ARP table (devices that block ping still show up), vendor from the MAC address, hostname and a rough guess of the device type based on gateway, name, vendor and TTL. No port scan. Asks for confirmation and warns to only scan networks you may scan. Put the IEEE `oui.txt` in `Modules/NetScan` for a complete vendor list. |
| PortScan | Services | `ports <Target> [Ports] [Timeout] [Banner] [Show] [Ask] [Export]` | TCP connect scan of one host, a range or a subnet. Ports as a single port, list, range or preset (`top`, `web`, `windows`, `mail`, `remote`, `all`). Shows open, closed (refused) and filtered (no answer, firewall), with service explanation, risk notes and optional banners. One host: a table; several hosts: a grid (up to 8 ports) or a list of open ports. Exports the open ports to CSV (all ports with `-Show all`) with the list separator of the computer (`;` on a Belgian Windows). |
| WebExplain | Web | `explain <Url> [Follow] [Timeout] [DnsServer]` | Shows step by step what happens when you open a website: DNS lookup (hosts file, local DNS cache or which DNS server answered, authoritative or not, with CNAMEs and TTL; `-DnsServer` asks a chosen server directly), the TCP three-way handshake, TLS with protocol, cipher and certificate chain, the HTTP request and the response headers with a short explanation. Ends with a timeline per phase and follows redirects. |
| VisualTrace | Connectivity | `trace <Target> [MaxHops] [Timeout] [Probes] [Resolve]` | Traceroute that draws the path hop by hop with latency bars, network zones (LAN, CGNAT, PUBLIC), latency jumps and a compact path map. |
| AdapterControl | This machine | `nic [Adapter] [Action]` | Choose an adapter and get the actions that fit it: renew or release the DHCP lease, restart, disable or enable the adapter, flush the DNS cache. Without parameters it shows a list of adapters and an action menu; `nic wifi renew` works directly. Windows only, most actions need administrator rights. Asks for confirmation before cutting the adapter of the default route. |
| LanInfo | This machine | `lan [Filter] [View] [All]` | Network configuration per adapter: IP, subnet mask, network range, gateway, DHCP (and DHCP server), DNS, IPv6, MAC and MTU. Marks the adapter of the default route and warns for APIPA addresses. `-View table` gives one line per adapter. |

## Writing a module

A module is a self contained folder inside `Modules/`. It describes itself to the core through its metadata: its name, the menu category it belongs to, the tools it offers and the alias for each tool. The core discovers the module at startup and adds it to the menus automatically.

The quickest start is to copy `Modules/_Template` to `Modules/<ModuleName>` and edit both files. Folders whose name starts with `_` are skipped by the loader.

`module.psd1` keys:

| Key | Required | Meaning |
|-----|----------|---------|
| `Name`, `Version` | yes | Module name and version. |
| `Category` | yes | Key of a category in `Core/Categories.psd1`: `local`, `discovery`, `connectivity`, `dns`, `services`, `web`, `calculators` or `security`. Several modules can share a category. |
| `Tools` | yes | List of tools. Each tool has `Name`, `Alias`, `Command` and optionally `Description`, `Parameters` and `Examples`. |
| `MinPSVersion` | no | Minimum PowerShell version, for example `'5.1'`. |

Per tool you can also set `Interactive = $true`. In menu mode the core then does not ask for the parameters, because the tool asks for its own input (like `nic`).

Every entry in `Parameters` has a `Name` that matches a parameter of the PowerShell function, plus `Required`, `Default` (shown in menus and help) and `Description`. The order of the list is the positional order in alias mode.

What the loader checks: both files exist, the metadata is complete, the module code loads, every `Command` is exported and every alias is unique, has no spaces, is not a number and is not a built in command. A module that fails a check is marked as failed in `modules` and the rest of NetRing keeps working. If two modules claim the same alias, the module that loads first (alphabetical folder order) keeps it.

Guidelines for every module:

1. Keep all logic inside the module folder.
2. Do not call functions of other modules directly.
3. Validate input and handle errors inside the module.
4. Provide a help text for every alias.
5. Use only ASCII characters in `.ps1`, `.psm1` and `.psd1` files. Windows PowerShell 5.1 misreads other characters in files saved without a BOM; build symbols with `[char]0x2500` and the like.
6. Write output with `Write-Host` and throw an error when something goes wrong. The core catches the error and shows it together with the usage line.

## Roadmap

- [x] Core: menus, aliases, module loader with error isolation
- [x] VisualTrace module (`trace`)
- [x] LanInfo module (`lan`)
- [x] AdapterControl module (`nic`)
- [x] WebExplain module (`explain`)
- [x] NetScan module (`scan`)
- [x] PortScan module (`ports`)
- [ ] Next modules: to be decided
