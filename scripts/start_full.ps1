<#
.SYNOPSIS
    启动 RepoBride 完整栈：Docker 基础设施 + FastAPI 后端 + Next.js 前端。

.DESCRIPTION
    与 scripts/start_rag.ps1 的区别：本脚本跑的是**完整栈**——真实的 PostgreSQL、
    etcd、MinIO、Milvus 容器，以及真实的 Qwen 本地 Embedding。
    start_rag.ps1 是 SQLite + deterministic embedding 的降级演示模式。

    脚本会自动设置 HF_ENDPOINT 镜像。这一点很关键：不设置的话，后端首次 RAG 调用时
    huggingface_hub 会去连 huggingface.co 校验元数据，国内网络会卡到超时。

.PARAMETER BackendPort
    后端端口，默认 8000。

.PARAMETER FrontendPort
    前端端口，默认 3000。

.PARAMETER SkipInfra
    跳过 Docker 容器检查/启动（容器已经在跑时可用）。

.PARAMETER NoFrontend
    只启动后端。

.EXAMPLE
    .\scripts\start_full.ps1
#>
param(
    [ValidateRange(1, 65535)]
    [int]$BackendPort = 8000,
    [ValidateRange(1, 65535)]
    [int]$FrontendPort = 3000,
    [switch]$SkipInfra,
    [switch]$NoFrontend
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$backendDirectory = Join-Path $projectRoot "backend"
$frontendDirectory = Join-Path $projectRoot "frontend"
$pythonPath = Join-Path $backendDirectory ".venv\Scripts\python.exe"
$dataDirectory = Join-Path $projectRoot ".data"
$backendOutputLog = Join-Path $dataDirectory "backend.out.log"
$backendErrorLog = Join-Path $dataDirectory "backend.err.log"
$frontendOutputLog = Join-Path $dataDirectory "frontend.out.log"
$frontendErrorLog = Join-Path $dataDirectory "frontend.err.log"

function Test-PortListening {
    param([int]$Port)
    return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

# ---------- 前置检查 ----------
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot ".env") -PathType Leaf)) {
    throw "未找到 .env。请先复制 .env.example 为 .env 并填写 LLM_API_KEY、GITHUB_TOKEN。"
}
if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
    throw "未找到 backend/.venv。请先创建虚拟环境并安装 backend/requirements.txt。"
}
if (-not $NoFrontend -and -not (Test-Path -LiteralPath (Join-Path $frontendDirectory "node_modules") -PathType Container)) {
    throw "未找到 frontend/node_modules。请先在 frontend 目录执行 npm install。"
}

New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null

# ---------- Docker 基础设施 ----------
if (-not $SkipInfra) {
    Write-Host "[1/4] 检查 Docker 基础设施..." -ForegroundColor Cyan

    $requiredContainers = @("devflow-ai-postgres", "devflow-ai-etcd", "devflow-ai-minio", "devflow-ai-milvus")
    $running = @(docker ps --format "{{.Names}}" 2>$null)
    $missing = @($requiredContainers | Where-Object { $_ -notin $running })

    if ($missing.Count -gt 0) {
        Write-Host "      启动中: $($missing -join ', ')" -ForegroundColor Yellow
        Push-Location $projectRoot
        try {
            docker compose up -d postgres etcd minio milvus
            if ($LASTEXITCODE -ne 0) { throw "docker compose 启动失败。" }
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Host "      4 个容器已在运行。" -ForegroundColor Green
    }

    # 容器调度完成 != 服务可用。下面两个等待无论容器是否刚启动都要做：
    # 容器带 restart: unless-stopped，Docker 重启后会自行恢复，此时"已在运行"
    # 的容器可能仍在初始化，跳过等待会让后端带着降级状态启动。

    Write-Host "      等待 PostgreSQL 健康..." -ForegroundColor Yellow
    $postgresReady = $false
    for ($attempt = 0; $attempt -lt 90; $attempt += 1) {
        $state = docker inspect --format "{{.State.Health.Status}}" devflow-ai-postgres 2>$null
        if ($state -eq "healthy") { $postgresReady = $true; break }
        Start-Sleep -Milliseconds 1000
    }
    if (-not $postgresReady) { throw "PostgreSQL 在 90 秒内没有进入健康状态。" }

    # Milvus standalone 要先连上 etcd 和 MinIO 才对外提供服务，容器 Up 时 19530
    # 通常还连不上。不等的话，后端会以"向量库 degraded"的状态启动，容易被误判成故障。
    Write-Host "      等待 Milvus 就绪..." -ForegroundColor Yellow
    $milvusReady = $false
    for ($attempt = 0; $attempt -lt 180; $attempt += 1) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:9091/healthz" -TimeoutSec 2 | Out-Null
            $milvusReady = $true
            break
        }
        catch {
            Start-Sleep -Milliseconds 1000
        }
    }
    if (-not $milvusReady) {
        Write-Host "      警告: Milvus 在 180 秒内没有就绪，RAG 向量检索会显示 degraded。" -ForegroundColor Yellow
    }
}
else {
    Write-Host "[1/4] 已跳过 Docker 检查 (-SkipInfra)" -ForegroundColor DarkGray
}

# ---------- 后端 ----------
Write-Host "[2/4] 启动后端..." -ForegroundColor Cyan

if (Test-PortListening -Port $BackendPort) {
    throw "端口 $BackendPort 已被占用。请先停止占用进程，或用 -BackendPort 指定其它端口。"
}

# 关键：本地 Qwen Embedding 走 HuggingFace 镜像，否则国内网络首次调用会超时。
$env:HF_ENDPOINT = "https://hf-mirror.com"
$env:PYTHONPATH = $backendDirectory

$backendProcess = Start-Process `
    -FilePath $pythonPath `
    -ArgumentList @("-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "$BackendPort") `
    -WorkingDirectory $backendDirectory `
    -RedirectStandardOutput $backendOutputLog `
    -RedirectStandardError $backendErrorLog `
    -WindowStyle Hidden `
    -PassThru

$backendReady = $false
for ($attempt = 0; $attempt -lt 120; $attempt += 1) {
    if ($backendProcess.HasExited) {
        throw "后端进程提前退出，请检查 $backendErrorLog。"
    }
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$BackendPort/health" -TimeoutSec 2 | Out-Null
        $backendReady = $true
        break
    }
    catch {
        Start-Sleep -Milliseconds 500
    }
}
if (-not $backendReady) {
    throw "后端在 60 秒内没有就绪，请检查 $backendErrorLog。"
}
Write-Host "      后端就绪 http://127.0.0.1:$BackendPort (PID $($backendProcess.Id))" -ForegroundColor Green

# ---------- 前端 ----------
$frontendProcess = $null

if (-not $NoFrontend) {
    Write-Host "[3/4] 启动前端..." -ForegroundColor Cyan

    if (Test-PortListening -Port $FrontendPort) {
        if (-not $backendProcess.HasExited) { Stop-Process -Id $backendProcess.Id }
        throw "端口 $FrontendPort 已被占用。请先停止占用进程，或用 -FrontendPort 指定其它端口。"
    }

    $env:NEXT_PUBLIC_API_BASE_URL = "http://127.0.0.1:$BackendPort"

    $frontendProcess = Start-Process `
        -FilePath "npm.cmd" `
        -ArgumentList @("run", "dev", "--", "-p", "$FrontendPort") `
        -WorkingDirectory $frontendDirectory `
        -RedirectStandardOutput $frontendOutputLog `
        -RedirectStandardError $frontendErrorLog `
        -WindowStyle Hidden `
        -PassThru

    $frontendReady = $false
    for ($attempt = 0; $attempt -lt 180; $attempt += 1) {
        if ($frontendProcess.HasExited) {
            if (-not $backendProcess.HasExited) { Stop-Process -Id $backendProcess.Id }
            throw "前端进程提前退出，请检查 $frontendErrorLog。"
        }
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$FrontendPort" -TimeoutSec 2 | Out-Null
            $frontendReady = $true
            break
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $frontendReady) {
        if (-not $backendProcess.HasExited) { Stop-Process -Id $backendProcess.Id }
        throw "前端在 90 秒内没有就绪，请检查 $frontendErrorLog。"
    }
    Write-Host "      前端就绪 http://127.0.0.1:$FrontendPort (PID $($frontendProcess.Id))" -ForegroundColor Green
}
else {
    Write-Host "[3/4] 已跳过前端 (-NoFrontend)" -ForegroundColor DarkGray
}

# ---------- 汇总 ----------
Write-Host "[4/4] RepoBride 完整栈已启动" -ForegroundColor Green
Write-Host ""
Write-Host "  前端      http://127.0.0.1:$FrontendPort" -ForegroundColor White
Write-Host "  后端      http://127.0.0.1:$BackendPort" -ForegroundColor White
Write-Host "  API 文档  http://127.0.0.1:$BackendPort/docs" -ForegroundColor White
Write-Host ""

$stopIds = @($backendProcess.Id)
if ($frontendProcess) { $stopIds += $frontendProcess.Id }
# 用 /T 一并结束子进程：npm run dev 会派生 node 子进程，只杀父进程会留下占用 3000 端口的孤儿进程。
Write-Host "  停止服务  taskkill /PID $($stopIds -join ' /PID ') /T /F" -ForegroundColor DarkGray
Write-Host "  日志      $backendOutputLog" -ForegroundColor DarkGray
if ($frontendProcess) {
    Write-Host "            $frontendOutputLog" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  说明：本脚本启动完整栈（真实 Postgres + Milvus + 本地 Qwen Embedding）。" -ForegroundColor DarkGray
Write-Host "        后端已注入 HF_ENDPOINT=https://hf-mirror.com，首次 RAG 调用会加载模型，约需 30-60 秒。" -ForegroundColor DarkGray
Write-Host "        如需降级演示模式（SQLite + deterministic embedding），请用 scripts/start_rag.ps1。" -ForegroundColor DarkGray
