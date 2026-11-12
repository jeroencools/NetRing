# NetRing core: console helpers (banner, colored output, small UI pieces).
# This file only contains ASCII characters on purpose: Windows PowerShell 5.1
# misreads non-ASCII characters in scripts saved without a BOM.

# NetRing color theme, inspired by the One Ring: gold, dark gold and the
# fire of Mount Doom. Change the colors here, the whole core follows.
# Allowed values: the 16 console colors (Get-Help about_Colors or
# [enum]::GetNames([System.ConsoleColor])).
$script:NRTheme = @{
    # Note: in Windows Terminal 'DarkYellow' is the real gold and 'Yellow'
    # is a pale cream color.
    Primary = 'DarkYellow'   # titles, prompt: gold
    Accent  = 'DarkYellow'   # underlines, tagline
    Key     = 'Yellow'       # menu numbers, aliases, usage lines: pale gold
    Text    = 'White'        # normal text
    Muted   = 'Gray'         # secondary text
    Dim     = 'DarkGray'     # hints, lines
    Ok      = 'DarkYellow'   # loaded, success
    Warn    = 'Yellow'       # warnings (always with [!])
    Error   = 'Red'          # errors: fire
    # Banner, top to bottom: the gold of the ring melting into the fire.
    Banner  = @('Yellow', 'Yellow', 'DarkYellow', 'DarkYellow', 'Red', 'DarkRed')
}

function Initialize-NRConsole {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    } catch {
        # Some hosts (for example the ISE) do not allow this. Not fatal.
    }
}

function Write-NRBanner {
    param([Parameter(Mandatory)][hashtable]$Context)

    $banner = @'
    _   __     __  ____  _
   / | / /__  / /_/ __ \(_)___  ____ _
  /  |/ / _ \/ __/ /_/ / / __ \/ __ `/
 / /|  /  __/ /_/ _, _/ / / / / /_/ /
/_/ |_/\___/\__/_/ |_/_/_/ /_/\__, /
                             /____/
'@
    Write-Host ''
    $lines = $banner -split "\r?\n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $color = $script:NRTheme.Banner[[math]::Min($i, $script:NRTheme.Banner.Count - 1)]
        Write-Host $lines[$i] -ForegroundColor $color
    }
    Write-Host '   "One NetRing to rule them all"' -ForegroundColor $script:NRTheme.Accent
    Write-Host ''
    $loaded = @($Context.Modules | Where-Object { $_.Status -eq 'Loaded' }).Count
    $failed = @($Context.Modules | Where-Object { $_.Status -eq 'Failed' }).Count
    Write-Host ("   v{0}  |  {1} module(s) loaded" -f $Context.Version, $loaded) -ForegroundColor $script:NRTheme.Muted -NoNewline
    if ($failed -gt 0) {
        Write-Host ("  |  {0} module(s) failed, type 'modules'" -f $failed) -ForegroundColor $script:NRTheme.Warn
    } else {
        Write-Host ''
    }
    Write-Host "   Type 'help' for help or 'aliases' for all shortcuts." -ForegroundColor $script:NRTheme.Dim
    Write-Host ''
}

function Write-NRTitle {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host ("  {0}" -f $Text) -ForegroundColor $script:NRTheme.Primary
    Write-Host ("  {0}" -f ('=' * $Text.Length)) -ForegroundColor $script:NRTheme.Accent
}

function Write-NRMenuItem {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [string]$Hint = ''
    )
    Write-Host ("   {0,3}) " -f $Key) -ForegroundColor $script:NRTheme.Key -NoNewline
    Write-Host ("{0,-32}" -f $Label) -ForegroundColor $script:NRTheme.Text -NoNewline
    if ($Hint) {
        Write-Host $Hint -ForegroundColor $script:NRTheme.Dim
    } else {
        Write-Host ''
    }
}

function Write-NRInfo {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("  [*] {0}" -f $Message) -ForegroundColor $script:NRTheme.Muted
}

function Write-NRWarn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("  [!] {0}" -f $Message) -ForegroundColor $script:NRTheme.Warn
}

function Write-NRError {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("  [x] {0}" -f $Message) -ForegroundColor $script:NRTheme.Error
}
