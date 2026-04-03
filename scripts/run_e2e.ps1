# ============================================================
# vibe-blog E2E Test Runner (PowerShell Windows version)
# Replica of run_e2e.sh
#
# Features:
#   1. Check/restart frontend and backend services
#   2. Run pytest E2E tests (real LLM calls)
#   3. Collect screenshots and logs to outputs directory
#
# Usage:
#   .\scripts\run_e2e.ps1                         # Full process (check services + run tests)
#   .\scripts\run_e2e.ps1 -Restart               # Force restart services then run tests
#   .\scripts\run_e2e.ps1 -TestOnly              # Skip service check, run tests directly
#   .\scripts\run_e2e.ps1 -Smoke                 # Run only smoke tests (TC-01 + TC-02)
#   .\scripts\run_e2e.ps1 -Chain                 # Run full chain closed-loop test (TC-16)
#   .\scripts\run_e2e.ps1 -Headed                # Headed mode (show browser window)
# ============================================================

param(
    [switch]$Restart,
    [switch]$TestOnly,
    [switch]$Smoke,
    [switch]$Chain,
    [switch]$Headed,
    [string[]]$ExtraArgs
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

# Color definitions
$RED = "Red"
$GREEN = "Green"
$YELLOW = "Yellow"
$BLUE = "Blue"
$NC = "Gray"

# Path definitions
$SCRIPT_DIR = Split-Path $MyInvocation.MyCommand.Path -Parent
$PROJECT_ROOT = Split-Path $SCRIPT_DIR -Parent
$BACKEND_DIR = Join-Path $PROJECT_ROOT "vibe-blog\backend"
$FRONTEND_DIR = Join-Path $PROJECT_ROOT "vibe-blog\frontend"
$E2E_DIR = Join-Path $PROJECT_ROOT "tests\e2e"
$SCREENSHOT_DIR = Join-Path $BACKEND_DIR "outputs\e2e_screenshots"
$LOG_DIR = Join-Path $PROJECT_ROOT "logs"

$BACKEND_PORT = 5001
$FRONTEND_PORT = 5173

# Utility functions
function Write-Color {
    param([string]$Message, [string]$Color = $NC)
    Write-Host $Message -ForegroundColor $Color
}

function Test-PortInUse {
    param([int]$Port)
    $result = netstat -ano | findstr ":$Port "
    return $null -ne $result
}

function Stop-PortProcess {
    param([int]$Port)
    Write-Color "Stopping processes on port $Port..." -Color $YELLOW
    $pids = netstat -ano | findstr ":$Port " | ForEach-Object { 
        $parts = $_ -split '\s+' | Where-Object { $_ -ne '' }
        $parts[-1]
    }
    foreach ($procId in $pids) {
        if ($procId -match '^\d+$') {
            taskkill /F /PID $procId 2>$null | Out-Null
        }
    }
    Start-Sleep -Seconds 1
}

function Wait-ServiceReady {
    param([int]$Port, [string]$Name, [int]$MaxAttempts = 30)
    Write-Color "Waiting for $Name (port $Port)..." -Color $YELLOW
    for ($attempt = 0; $attempt -lt $MaxAttempts; $attempt++) {
        if (Test-PortInUse $Port) {
            Write-Color "$Name ready" -Color $GREEN
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Color "$Name startup timeout" -Color $RED
    return $false
}

# Main process
Write-Color "============================================================" -Color $BLUE
Write-Color "  vibe-blog E2E Tests" -Color $BLUE
Write-Color "============================================================" -Color $BLUE
Write-Color "  Project: $PROJECT_ROOT" -Color $NC
Write-Color "  Mode: $(if ($Chain) { 'chain' } elseif ($Smoke) { 'smoke' } else { 'full' })" -Color $NC
Write-Color "  Browser: $(if ($Headed) { 'headed' } else { 'headless' })" -Color $NC
Write-Host ""

$TEST_EXIT = 0
$backendProcess = $null
$frontendProcess = $null

# Step 1: Service management
if (-not $TestOnly) {
    Write-Color "[Step 1] Checking service status" -Color $BLUE

    if ($Restart) {
        Write-Color "Force restarting services..." -Color $YELLOW
        Stop-PortProcess $BACKEND_PORT
        Stop-PortProcess $FRONTEND_PORT
    }

    # Check backend
    if (-not (Test-PortInUse $BACKEND_PORT)) {
        Write-Color "Backend not running, starting..." -Color $YELLOW
        
        # Ensure log directory exists
        if (-not (Test-Path $LOG_DIR)) {
            New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
        }
        
        # Start backend process (using uv run)
        $backendProcess = Start-Process -FilePath "uv" `
            -ArgumentList "run", "app.py" `
            -WorkingDirectory $BACKEND_DIR `
            -PassThru `
            -NoNewWindow
        
        # Wait for backend to be ready
        if (-not (Wait-ServiceReady $BACKEND_PORT "Backend")) {
            Write-Color "Backend startup failed" -Color $RED
            $backendProcess | Stop-Process -Force -ErrorAction SilentlyContinue | Out-Null
            exit 1
        }
    } else {
        Write-Color "Backend already running" -Color $GREEN
    }

    # Check frontend
    if (-not (Test-PortInUse $FRONTEND_PORT)) {
        Write-Color "Frontend not running, starting..." -Color $YELLOW
        
        # Ensure log directory exists
        if (-not (Test-Path $LOG_DIR)) {
            New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
        }
        
        # Start frontend process (use npm.cmd on Windows)
        $npmPath = "npm.cmd"
        $frontendProcess = Start-Process -FilePath $npmPath `
            -ArgumentList "run", "dev" `
            -WorkingDirectory $FRONTEND_DIR `
            -PassThru `
            -NoNewWindow
        
        # Wait for frontend to be ready
        if (-not (Wait-ServiceReady $FRONTEND_PORT "Frontend")) {
            Write-Color "Frontend startup failed" -Color $RED
            $frontendProcess | Stop-Process -Force -ErrorAction SilentlyContinue | Out-Null
            exit 1
        }
    } else {
        Write-Color "Frontend already running" -Color $GREEN
    }
} else {
    Write-Color "[Step 1] Skipping service check (-TestOnly)" -Color $BLUE
    if (-not (Test-PortInUse $BACKEND_PORT) -or -not (Test-PortInUse $FRONTEND_PORT)) {
        Write-Color "Services not running, please start them or remove -TestOnly" -Color $RED
        exit 1
    }
}

Write-Host ""

# Step 2: Prepare test environment
Write-Color "[Step 2] Preparing test environment" -Color $BLUE

# Clean old screenshots
if (Test-Path $SCREENSHOT_DIR) {
    $oldScreenshots = @(Get-ChildItem -Path $SCREENSHOT_DIR -Filter "*.png" -ErrorAction SilentlyContinue)
    $oldLogs = @(Get-ChildItem -Path $SCREENSHOT_DIR -Filter "*.json" -ErrorAction SilentlyContinue)
    $oldCount = $oldScreenshots.Count + $oldLogs.Count
    
    if ($oldCount -gt 0) {
        Write-Color "  Cleaning $oldCount old screenshots and logs" -Color $NC
        Remove-Item -Path "$SCREENSHOT_DIR\*.png" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$SCREENSHOT_DIR\*.json" -Force -ErrorAction SilentlyContinue
    }
}

# Create screenshot directory
if (-not (Test-Path $SCREENSHOT_DIR)) {
    New-Item -ItemType Directory -Path $SCREENSHOT_DIR -Force | Out-Null
}

# Set environment variables
$env:RUN_E2E_TESTS = "1"
if ($Headed) {
    $env:E2E_HEADED = "1"
    $env:E2E_SLOW_MO = "300"
}

Write-Color "Environment ready" -Color $GREEN
Write-Host ""

# Step 3: Run tests
Write-Color "[Step 3] Running E2E tests" -Color $BLUE

Set-Location $PROJECT_ROOT

$pytestArgs = @("-v", "--tb=short")
if ($ExtraArgs) {
    $pytestArgs += $ExtraArgs
}

$logFile = Join-Path $LOG_DIR "e2e_result_$(Get-Date -Format 'HHmmss').log"

if ($Smoke) {
    Write-Color "  Running smoke tests (TC-01 + TC-02)..." -Color $YELLOW
    $testFiles = @(
        (Join-Path $E2E_DIR "test_tc01_home_load.py"),
        (Join-Path $E2E_DIR "test_tc02_blog_gen.py")
    )
    $command = "python -m pytest $($testFiles -join ' ') $($pytestArgs -join ' ')"
} elseif ($Chain) {
    Write-Color "  Running full chain closed-loop test (TC-16)..." -Color $YELLOW
    $testFile = Join-Path $E2E_DIR "test_tc16_full_chain.py"
    $command = "python -m pytest $testFile $($pytestArgs -join ' ')"
} else {
    Write-Color "  Running full E2E tests..." -Color $YELLOW
    $command = "python -m pytest tests/e2e/ $($pytestArgs -join ' ')"
}

Write-Color "  Executing: $command" -Color $NC

# Run tests and output to console and log file
Invoke-Expression $command 2>&1 | Tee-Object -FilePath $logFile
$TEST_EXIT = $LASTEXITCODE

Write-Host ""

# Step 4: Collect results
Write-Color "[Step 4] Test results" -Color $BLUE

$screenshotCount = 0
$logCount = 0

if (Test-Path $SCREENSHOT_DIR) {
    $screenshotCount = @(Get-ChildItem -Path $SCREENSHOT_DIR -Filter "*.png" -ErrorAction SilentlyContinue).Count
    $logCount = @(Get-ChildItem -Path $SCREENSHOT_DIR -Filter "*.json" -ErrorAction SilentlyContinue).Count
}

Write-Color "  Screenshots: ${screenshotCount} → $SCREENSHOT_DIR" -Color $NC
Write-Color "  Logs: ${logCount} → $SCREENSHOT_DIR" -Color $NC

# Step 5: Log analysis
Write-Color "`n[Step 5] Log analysis" -Color $BLUE

$analysisScript = Join-Path $SCRIPT_DIR "analyze_e2e_logs.py"
if (Test-Path $analysisScript) {
    $analysisReport = Join-Path $LOG_DIR "e2e_analysis_$(Get-Date -Format 'HHmmss').json"
    try {
        python $analysisScript --since 10m --output $analysisReport 2>$null
        
        if (Test-Path $analysisReport) {
            $healthJson = Get-Content $analysisReport -Raw | ConvertFrom-Json
            $health = $healthJson.health.status
            $issues = $healthJson.health.total_issues
            
            if ($health -eq "GREEN") {
                Write-Color "  Health: $health (issues: $issues)" -Color $GREEN
            } elseif ($health -eq "RED") {
                Write-Color "  Health: $health (issues: $issues)" -Color $RED
            } else {
                Write-Color "  Health: $health (issues: $issues)" -Color $YELLOW
            }
            Write-Color "  Analysis report: $analysisReport" -Color $NC
        }
    } catch {
        Write-Color "  Log analysis skipped" -Color $YELLOW
    }
} else {
    Write-Color "  Log analysis script not found: $analysisScript" -Color $YELLOW
}

if ($TEST_EXIT -eq 0) {
    Write-Host ""
    Write-Color "============================================================" -Color $GREEN
    Write-Color "  E2E tests all passed" -Color $GREEN
    Write-Color "============================================================" -Color $GREEN
} else {
    Write-Host ""
    Write-Color "============================================================" -Color $RED
    Write-Color "  E2E tests failed (exit code: $TEST_EXIT)" -Color $RED
    Write-Color "============================================================" -Color $RED
    Write-Color "  View screenshots: explorer $SCREENSHOT_DIR" -Color $NC
    Write-Color "  View logs: dir $LOG_DIR\e2e_result_*.log" -Color $NC
}

# Clean up started processes (always clean up even if services were already running)
Write-Color "`n[Cleanup] Stopping services" -Color $YELLOW

# Kill backend process if we started it
if ($backendProcess) {
    Write-Color "  Stopping backend process..." -Color $YELLOW
    $backendProcess | Stop-Process -Force -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 1
}

# Kill frontend process if we started it  
if ($frontendProcess) {
    Write-Color "  Stopping frontend process..." -Color $YELLOW
    $frontendProcess | Stop-Process -Force -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 1
}

# Clean up any processes on the ports (in case they weren't properly stopped)
Write-Color "  Cleaning up any remaining processes on ports $BACKEND_PORT and $FRONTEND_PORT..." -Color $YELLOW
Stop-PortProcess $BACKEND_PORT
Stop-PortProcess $FRONTEND_PORT

Write-Color "  Services cleanup complete" -Color $GREEN

exit $TEST_EXIT
