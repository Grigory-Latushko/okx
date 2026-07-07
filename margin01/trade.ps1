param(
  [string]$ConfigPath = ".\config.json",
  [switch]$ForceLive,
  [switch]$DebugMode
)

if (-not $global:candleCache) { $global:candleCache = @{} }

# ---------------- helpers ----------------
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }

function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }

function LogConsole($msg, $type = "INFO") {
    $ts = Format-Time
    Write-Host "[$ts][$type] $msg"
}
function Mask { param([string]$s) if (-not $s) { return "" } if ($s.Length -le 8) { return $s.Substring(0,2) + "..." } return $s.Substring(0,4) + "..." + $s.Substring($s.Length-4,4) } 

function Log { param([string]$msg, [string]$level = "INFO") switch ($level.ToUpper()) { "INFO"  { Write-Host "[INFO ] $msg" -ForegroundColor Gray } "OK"    { Write-Host "[ OK  ] $msg" -ForegroundColor Green } "WARN"  { Write-Host "[WARN ] $msg" -ForegroundColor Yellow } "ERROR" { Write-Host "[ERR  ] $msg" -ForegroundColor Red } "DEBUG" { if ($DebugMode) { Write-Host "[DBG  ] $msg" -ForegroundColor Cyan } } } }

function Get-NowTimestamp { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }