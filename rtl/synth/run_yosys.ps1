param(
    [string]$Yosys = "yosys"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$outputDirectory = Join-Path $repositoryRoot "build\synthesis"
$yosysCommand = Get-Command $Yosys -ErrorAction SilentlyContinue
if (-not $yosysCommand) {
    throw "Yosys executable '$Yosys' was not found. Install Yosys or pass its path with -Yosys."
}
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

Push-Location $repositoryRoot
try {
    & $yosysCommand.Source -s "rtl/synth/synth.ys" 2>&1 |
        Tee-Object -FilePath (Join-Path $outputDirectory "yosys.log")
    if ($LASTEXITCODE -ne 0) {
        throw "Yosys exited with code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}
