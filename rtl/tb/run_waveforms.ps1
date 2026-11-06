param(
    [string]$Iverilog = "iverilog",
    [string]$Vvp = "vvp"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$outputDirectory = Join-Path $repositoryRoot "build\waves"
$image = Join-Path $outputDirectory "mesi_2core_concurrent_tb.vvp"
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

Push-Location $repositoryRoot
try {
    & $Iverilog -g2012 -Wall -s mesi_2core_concurrent_tb -o $image `
        "rtl\mesi_controller.sv" "rtl\mesi_bus_arbiter.sv" `
        "rtl\tb\mesi_2core_concurrent_tb.sv"
    if ($LASTEXITCODE -ne 0) {
        throw ("Icarus compilation failed with code {0}" -f $LASTEXITCODE)
    }

    $scenarios = @(
        "read_miss",
        "write_invalidation",
        "modified_intervention",
        "simultaneous",
        "backpressure",
        "completion",
        "reset_pending"
    )
    foreach ($scenario in $scenarios) {
        $wave = Join-Path $outputDirectory "$scenario.vcd"
        $log = Join-Path $outputDirectory "$scenario.log"
        & $Vvp $image "+CASE=$scenario" "+WAVE=$wave" "+LOG=$log"
        if ($LASTEXITCODE -ne 0) {
            throw ("Simulation failed for {0} with code {1}" -f $scenario, $LASTEXITCODE)
        }
    }
}
finally {
    Pop-Location
}
