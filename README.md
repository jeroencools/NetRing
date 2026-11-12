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

> **Status:** early development. The framework and its modules are being built step by step. Sections marked *(planned)* describe the intended design and are not available yet.

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

- Windows with PowerShell *(minimum version to be defined)*
- Administrator rights may be needed for some network tools

## Getting started

*(planned)*

```powershell
# Clone or download the repository
cd NetRing

# Start the toolkit
.\NetRing.ps1
```

If script execution is blocked on your system, allow it for the current session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Usage

### Menu mode

After starting NetRing you see the main menu. Type a number and press Enter to go one level deeper. Use `0` (or `back`) to return to the previous menu.


### Alias mode

Navigating with numbers is great for exploring but slow when you know exactly what you want. Every tool therefore also has an alias. Instead of typing

```
5 [Enter]  3 [Enter]  2 [Enter]  ...
```

you type the alias followed by its parameters on a single line:

```
netring> ALIAS PARAMETER PARAMETER
```

Useful built in commands *(planned)*:

| Command | Description |
|---------|-------------|
| `help` | Show general help. |
| `help <alias>` | Show help and parameters for a specific tool. |
| `aliases` | List all available aliases. |
| `modules` | List loaded modules and their status. |
| `back` / `0` | Return to the previous menu. |
| `exit` | Quit NetRing. |

## Project structure

*(planned, may change during development)*

```
NetRing/
├── NetRing.ps1          # Entry point
├── Core/                # Menu engine, alias parser, module loader
├── Modules/             # One folder per module
│   └── <ModuleName>/
│       ├── module.psd1  # Metadata: name, version, menu entries, aliases
│       └── module.psm1  # Tool logic
└── README.md
```

## Writing a module

*(planned)*

A module is a self contained folder inside `Modules/`. It describes itself to the core through its metadata: its name, the menu category it belongs to, the tools it offers and the alias for each tool. The core discovers the module at startup and adds it to the menus automatically.

Guidelines for every module:

1. Keep all logic inside the module folder.
2. Do not call functions of other modules directly.
3. Validate input and handle errors inside the module.
4. Provide a help text for every alias.